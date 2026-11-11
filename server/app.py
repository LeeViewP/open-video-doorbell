"""doorbell-server: everything the phones need, behind Cloudflare Access.
See README.md.
"""

import asyncio
import hmac
import json
import logging
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from aiohttp import ClientError, ClientSession, ClientTimeout, WSMsgType, web

SCOPES = ["https://www.googleapis.com/auth/firebase.messaging"]
log = logging.getLogger("doorbell-server")


# --------------------------------------------------------------------------
# FCM


def google_token_provider(credentials_path):
    """Returns a callable that yields a valid OAuth token for FCM, refreshing
    it from the service-account key when it expires."""
    # Imported here so the rest of the module (and its tests) work without
    # google-auth installed.
    import google.auth.transport.requests
    from google.oauth2 import service_account

    creds = service_account.Credentials.from_service_account_file(
        credentials_path, scopes=SCOPES
    )

    def token():
        if not creds.valid:
            creds.refresh(google.auth.transport.requests.Request())
        return creds.token

    return token


def post_json(url, token, payload, timeout=10):
    """POSTs JSON with a bearer token; returns (status, text) for any answer."""
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, res.read().decode()
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode()


class Sender:
    def __init__(self, project_id, token_provider, topic="doorbell",
                 debounce_seconds=10.0, endpoint=None):
        self.topic = topic
        self.debounce_seconds = debounce_seconds
        self.endpoint = endpoint or (
            f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
        )
        self._token = token_provider
        self._lock = threading.Lock()
        self._last_ring = 0.0
        # Of the last ring that went out; the history files it under this.
        self.last_ring_id = ""

    def _message(self, data):
        # Data-only message: a notification block would be shown by the system
        # and never reach the app's handler, so no call screen could appear.
        return {
            "message": {
                "topic": self.topic,
                "data": data,
                "android": {"priority": "HIGH", "ttl": "30s"},
            }
        }

    def payload(self, title, body, ring_id=""):
        return self._message({
            "type": "doorbell",
            "title": title,
            "body": body,
            # Names this ring, so answering it can stop it on the other phones.
            "ring_id": ring_id,
            # Unix ms; the app shows how long the push took to arrive.
            "sent_at": str(int(time.time() * 1000)),
        })

    def answered(self, ring_id, by):
        """Tells every phone that [by] answered ring [ring_id], so the others
        stop ringing. Returns (http_status, text). Blocking."""
        return post_json(self.endpoint, self._token(), self._message(
            {"type": "doorbell_answered", "ring_id": ring_id, "by": by}))

    def ring(self, title="Doorbell", body="Someone is at the door"):
        """Returns (http_status, text). 429 when debounced. Blocking."""
        with self._lock:
            now = time.monotonic()
            if now - self._last_ring < self.debounce_seconds:
                return 429, "debounced"
            self._last_ring = now
        ring_id = uuid.uuid4().hex
        try:
            status, text = post_json(
                self.endpoint, self._token(),
                self.payload(title, body, ring_id))
        except Exception:
            with self._lock:
                self._last_ring = 0.0
            raise
        if status >= 300:
            # A failed send must not swallow the next press.
            with self._lock:
                self._last_ring = 0.0
        else:
            self.last_ring_id = ring_id
        return status, text


# --------------------------------------------------------------------------
# History


class History:
    """The last rings, each with the picture taken when it rang, who answered
    and who opened; door openings with no ring before them too. Newest first.
    Kept in [path] (index.json and <id>.jpg) when given, else in memory."""

    def __init__(self, path="", keep=100, attach_seconds=300):
        self.path = path
        self.keep = keep
        # An opening this soon after a ring belongs to that ring.
        self.attach_seconds = attach_seconds
        self._entries = []
        self._pictures = {}
        if path:
            os.makedirs(path, exist_ok=True)
            try:
                with open(self._index(), encoding="utf-8") as f:
                    self._entries = json.load(f)
            except FileNotFoundError:
                pass
            except ValueError:
                log.warning("history index unreadable, starting empty")

    def _index(self):
        return os.path.join(self.path, "index.json")

    def _picture_file(self, entry_id):
        return os.path.join(self.path, f"{entry_id}.jpg")

    def _save(self):
        if not self.path:
            return
        tmp = self._index() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self._entries, f)
        os.replace(tmp, self._index())

    def _find(self, entry_id):
        return next((e for e in self._entries if e["id"] == entry_id), None)

    def _add(self, entry):
        self._entries.insert(0, entry)
        for old in self._entries[self.keep:]:
            self._pictures.pop(old["id"], None)
            if self.path and old.get("picture"):
                try:
                    os.remove(self._picture_file(old["id"]))
                except FileNotFoundError:
                    pass
        del self._entries[self.keep:]
        self._save()

    def add_ring(self, ring_id, when):
        self._add({"id": ring_id, "kind": "ring", "time": when,
                   "answered_by": None, "opened_by": None, "picture": False})

    def set_picture(self, ring_id, jpeg):
        entry = self._find(ring_id)
        if entry is None:
            return
        if self.path:
            with open(self._picture_file(ring_id), "wb") as f:
                f.write(jpeg)
        else:
            self._pictures[ring_id] = jpeg
        entry["picture"] = True
        self._save()

    def answered(self, ring_id, by):
        entry = self._find(ring_id)
        if entry is not None and not entry["answered_by"]:
            entry["answered_by"] = by
            self._save()

    def opened(self, by, when):
        ring = next((e for e in self._entries if e["kind"] == "ring"), None)
        if (ring is not None and not ring["opened_by"]
                and when - ring["time"] <= self.attach_seconds):
            ring["opened_by"] = by
            self._save()
        else:
            self._add({"id": uuid.uuid4().hex, "kind": "open", "time": when,
                       "by": by})

    def entries(self):
        return [dict(e) for e in self._entries]

    def picture(self, entry_id):
        if not re.fullmatch(r"[0-9a-f]{32}", entry_id or ""):
            return None
        if not self.path:
            return self._pictures.get(entry_id)
        try:
            with open(self._picture_file(entry_id), "rb") as f:
                return f.read()
        except FileNotFoundError:
            return None


# --------------------------------------------------------------------------
# Who is calling


class Clients:
    """The phones allowed on /api: [{"name", "client_id", "client_secret"}],
    one Cloudflare Access service token each."""

    def __init__(self, entries):
        self._by_id = {}
        for e in entries:
            if not (e.get("name") and e.get("client_id")
                    and e.get("client_secret")):
                raise ValueError(
                    "each client needs name, client_id and client_secret")
            if e["client_id"] in self._by_id:
                raise ValueError(f"client_id of {e['name']} is used twice")
            self._by_id[e["client_id"]] = e

    def __len__(self):
        return len(self._by_id)

    def by_id(self, client_id):
        e = self._by_id.get(client_id)
        return e["name"] if e else None

    def by_headers(self, client_id, secret):
        e = self._by_id.get(client_id)
        if e is None:
            # Same work either way, so a wrong id and a wrong secret look alike.
            hmac.compare_digest(secret.encode(), b"x" * len(secret))
            return None
        ok = hmac.compare_digest(e["client_secret"].encode(), secret.encode())
        return e["name"] if ok else None


class AccessJwt:
    """Checks the JWT Cloudflare Access adds to every request it lets through
    (Cf-Access-Jwt-Assertion). For a service token its `common_name` is the
    token's client id."""

    def __init__(self, team_domain, aud, jwk_client=None):
        import jwt  # PyJWT; only needed when Access is configured

        self._jwt = jwt
        self.issuer = f"https://{team_domain}"
        self.aud = aud
        self._keys = jwk_client or jwt.PyJWKClient(
            f"{self.issuer}/cdn-cgi/access/certs", cache_keys=True,
            lifespan=3600)

    def client_id(self, token):
        """The service token's client id; raises jwt.PyJWTError if the JWT is
        not one of Access's for this application. Blocking (key fetch)."""
        key = self._keys.get_signing_key_from_jwt(token).key
        claims = self._jwt.decode(
            token, key, algorithms=["RS256"], audience=self.aud,
            issuer=self.issuer)
        return claims.get("common_name", "")


async def identify(request):
    """The calling phone's name, or None."""
    clients = request.app[CLIENTS]
    access = request.app[ACCESS]
    token = request.headers.get("Cf-Access-Jwt-Assertion")
    if token and access is not None:
        try:
            client_id = await asyncio.to_thread(access.client_id, token)
        except Exception as exc:  # bad JWT, or the keys could not be fetched
            log.warning("rejected Access JWT: %s", exc)
            return None
        return clients.by_id(client_id)
    return clients.by_headers(
        request.headers.get("CF-Access-Client-Id", ""),
        request.headers.get("CF-Access-Client-Secret", ""))


WHO = web.RequestKey("who", str)


@web.middleware
async def api_auth(request, handler):
    if request.path.startswith("/api/"):
        who = await identify(request)
        if who is None:
            return web.json_response({"error": "Not allowed."}, status=401)
        request[WHO] = who
    return await handler(request)


# --------------------------------------------------------------------------
# Home Assistant and go2rtc


class UpstreamError(Exception):
    """Home Assistant or go2rtc failed; the message is for the app's user."""


class HomeAssistant:
    def __init__(self, session, url, token, lock_entity, lock_service="unlock",
                 camera_entity=""):
        self._session = session
        self._url = url.rstrip("/")
        self._headers = {"Authorization": f"Bearer {token}"}
        self.lock_entity = lock_entity
        self.lock_service = lock_service
        self.camera_entity = camera_entity

    async def _request(self, method, path, **kwargs):
        try:
            async with self._session.request(
                    method, self._url + path, headers=self._headers,
                    **kwargs) as res:
                body = await res.read()
                status = res.status
        except (ClientError, asyncio.TimeoutError) as exc:
            raise UpstreamError(
                f"The server cannot reach Home Assistant ({exc}).") from exc
        if status == 401:
            raise UpstreamError(
                "Home Assistant rejected the server's token.")
        if status == 404:
            raise UpstreamError(f"Home Assistant has no {path.split('/')[-1]}.")
        if status >= 300:
            raise UpstreamError(f"Home Assistant answered {status}.")
        return body

    async def lock_state(self):
        """(state, friendly name) of the lock, e.g. ("locked", "Gate")."""
        body = await self._request("GET", f"/api/states/{self.lock_entity}")
        try:
            entity = json.loads(body)
            state = str(entity["state"])
            name = (entity.get("attributes") or {}).get("friendly_name")
        except (ValueError, KeyError, TypeError, AttributeError) as exc:
            raise UpstreamError(
                "Unexpected answer from Home Assistant.") from exc
        return state, str(name or self.lock_entity)

    async def open(self):
        await self._request(
            "POST", f"/api/services/lock/{self.lock_service}",
            json={"entity_id": self.lock_entity})

    async def snapshot(self):
        return await self._request(
            "GET", f"/api/camera_proxy/{self.camera_entity}")


async def watch_visitor(session, ha_url, token, entity, on_press,
                        retry_delay=5.0):
    """Calls on_press() each time [entity] (the doorbell's Visitor sensor)
    turns on, from Home Assistant's websocket API; reconnects for ever.
    Non-admin users may subscribe to state_changed, so the server's own
    Home Assistant user is enough: no automation needed in Home Assistant."""
    url = ha_url.rstrip("/").replace("http", "ws", 1) + "/api/websocket"
    while True:
        try:
            async with session.ws_connect(url, heartbeat=30) as ws:
                await ws.receive_json()  # auth_required
                await ws.send_json({"type": "auth", "access_token": token})
                auth = await ws.receive_json()
                if auth.get("type") != "auth_ok":
                    raise UpstreamError(f"websocket auth: {auth.get('type')}")
                await ws.send_json({"id": 1, "type": "subscribe_events",
                                    "event_type": "state_changed"})
                log.info("watching %s", entity)
                async for msg in ws:
                    if msg.type != WSMsgType.TEXT:
                        break
                    data = json.loads(msg.data)
                    if data.get("type") != "event":
                        continue
                    ev = data["event"]["data"]
                    if ev.get("entity_id") != entity:
                        continue
                    new = (ev.get("new_state") or {}).get("state")
                    old = (ev.get("old_state") or {}).get("state")
                    if new == "on" and old != "on":
                        log.info("%s pressed", entity)
                        await on_press()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # HA restarting, network, bad token
            log.warning("visitor watch: %s; retrying in %.0f s", exc,
                        retry_delay)
        await asyncio.sleep(retry_delay)


def go2rtc_url(base, path, stream, scheme=None):
    """go2rtc API URL for the stream, e.g. /api/ws or /api/frame.jpeg."""
    parts = urllib.parse.urlsplit(base.rstrip("/"))
    if scheme is None:
        scheme = parts.scheme
    elif parts.scheme == "https":
        scheme += "s"
    query = urllib.parse.urlencode({"src": stream})
    return urllib.parse.urlunsplit(
        (scheme, parts.netloc, parts.path + path, query, ""))


# --------------------------------------------------------------------------
# Handlers


async def health(_request):
    return web.Response(text="ok")


async def ring(request):
    secret = request.app[RING_SECRET]
    given = request.headers.get("X-Secret", "")
    if not hmac.compare_digest(given.encode(), secret.encode()):
        return web.Response(status=401, text="unauthorized")
    raw = await request.read()
    try:
        body = json.loads(raw) if raw else {}
    except ValueError:
        return web.Response(status=400, text="invalid json")
    if not isinstance(body, dict):
        return web.Response(status=400, text="body must be a json object")
    try:
        status, text = await asyncio.to_thread(
            request.app[SENDER].ring,
            str(body.get("title", "Doorbell")),
            str(body.get("body", "Someone is at the door")))
    except Exception as exc:  # network or auth failure
        log.exception("ring failed")
        return web.Response(status=502, text=f"send failed: {exc}")
    if status == 429:
        return web.Response(text="ignored: too soon after the last press")
    if status >= 300:
        log.error("FCM answered %s: %s", status, text)
        return web.Response(status=502, text=f"FCM answered {status}")
    await record_ring(request.app)
    return web.Response(text="rang")


async def record_ring(app):
    """Files the ring that just went out in the history, with the picture
    of who is at the door."""
    ring_id = app[SENDER].last_ring_id
    app[HISTORY].add_ring(ring_id, time.time())
    try:
        app[HISTORY].set_picture(ring_id, await fetch_snapshot(app))
    except (UpstreamError, ClientError, asyncio.TimeoutError) as exc:
        log.warning("no picture for ring %s: %s", ring_id, exc)


async def state(request):
    try:
        lock, name = await request.app[HA].lock_state()
    except UpstreamError as exc:
        return web.json_response({"error": str(exc)}, status=502)
    return web.json_response({"lock": lock, "name": name})


async def history_list(request):
    return web.json_response({"entries": request.app[HISTORY].entries()})


async def history_picture(request):
    image = request.app[HISTORY].picture(request.match_info["id"])
    if image is None:
        return web.json_response({"error": "No picture."}, status=404)
    return web.Response(body=image, content_type="image/jpeg")


async def open_door(request):
    who = request[WHO]
    app = request.app
    # One opening per interval, whoever asks: a stuck button or a replayed
    # request cannot hammer the lock.
    now = time.monotonic()
    if now - app[LAST_OPEN][0] < app[OPEN_INTERVAL]:
        return web.json_response(
            {"error": "Just opened. Wait a moment."}, status=429)
    app[LAST_OPEN][0] = now
    try:
        await app[HA].open()
    except UpstreamError as exc:
        app[LAST_OPEN][0] = 0.0
        log.warning("door open by %s failed: %s", who, exc)
        return web.json_response({"error": str(exc)}, status=502)
    log.info("door opened by %s", who)
    app[HISTORY].opened(who, time.time())
    return web.json_response({"ok": True})


async def answered(request):
    """A phone answered (or unlocked from) ring {"ring_id"}: the other phones
    get a push to stop ringing."""
    try:
        body = await request.json()
        ring_id = str(body["ring_id"])
    except (ValueError, KeyError, TypeError):
        return web.json_response({"error": "ring_id missing."}, status=400)
    who = request[WHO]
    log.info("%s answered ring %s", who, ring_id)
    request.app[HISTORY].answered(ring_id, who)
    try:
        status, text = await asyncio.to_thread(
            request.app[SENDER].answered, ring_id, who)
    except Exception as exc:
        log.warning("answered push failed: %s", exc)
        return web.json_response({"error": f"Push failed: {exc}"}, status=502)
    if status >= 300:
        log.error("FCM answered %s: %s", status, text)
        return web.json_response({"error": f"FCM answered {status}."},
                                 status=502)
    return web.json_response({"ok": True})


async def fetch_snapshot(app):
    """The doorbell's picture now: Home Assistant's camera when set, else a
    go2rtc frame. Raises UpstreamError or the client's errors."""
    ha = app[HA]
    if ha.camera_entity:
        return await ha.snapshot()
    url = go2rtc_url(app[GO2RTC], "/api/frame.jpeg", app[STREAM])
    async with app[SESSION].get(url) as res:
        if res.status != 200:
            raise UpstreamError(f"go2rtc answered {res.status}.")
        return await res.read()


async def snapshot(request):
    headers = {"Cache-Control": "no-store"}
    try:
        image = await fetch_snapshot(request.app)
    except UpstreamError as exc:
        return web.json_response({"error": str(exc)}, status=502)
    except (ClientError, asyncio.TimeoutError) as exc:
        return web.json_response(
            {"error": f"The server cannot reach go2rtc ({exc})."}, status=502)
    return web.Response(body=image, content_type="image/jpeg", headers=headers)


async def signaling(request):
    """Relays go2rtc's WebRTC signaling (/api/ws) for the configured stream;
    the app's own `src` is ignored, so a phone can only reach the doorbell."""
    app = request.app
    phone = web.WebSocketResponse(heartbeat=30)
    await phone.prepare(request)
    url = go2rtc_url(app[GO2RTC], "/api/ws", app[STREAM], scheme="ws")
    try:
        go2rtc = await app[SESSION].ws_connect(url, heartbeat=30)
    except (ClientError, asyncio.TimeoutError) as exc:
        await phone.send_json(
            {"type": "error", "value": f"The server cannot reach go2rtc ({exc})."})
        await phone.close()
        return phone

    async def pump(src, dst):
        async for msg in src:
            if msg.type == WSMsgType.TEXT:
                await dst.send_str(msg.data)
            elif msg.type == WSMsgType.BINARY:
                await dst.send_bytes(msg.data)
            else:
                break

    log.info("%s: video (%s)", request[WHO], request.query.get("kind", "view"))
    tasks = [asyncio.create_task(pump(phone, go2rtc)),
             asyncio.create_task(pump(go2rtc, phone))]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            t.cancel()
        await go2rtc.close()
        await phone.close()
    return phone


# --------------------------------------------------------------------------
# App

CLIENTS = web.AppKey("clients", Clients)
ACCESS = web.AppKey("access", object)
RING_SECRET = web.AppKey("ring_secret", str)
SENDER = web.AppKey("sender", Sender)
HA = web.AppKey("ha", HomeAssistant)
GO2RTC = web.AppKey("go2rtc", str)
STREAM = web.AppKey("stream", str)
SESSION = web.AppKey("session", ClientSession)
LAST_OPEN = web.AppKey("last_open", list)
OPEN_INTERVAL = web.AppKey("open_interval", float)
HISTORY = web.AppKey("history", History)


async def ring_from_visitor(app):
    """A press seen on the Visitor sensor: ring like /ring does."""
    try:
        status, text = await asyncio.to_thread(app[SENDER].ring)
    except Exception:
        log.exception("ring failed")
        return
    if status == 429:
        return
    if status >= 300:
        log.error("FCM answered %s: %s", status, text)
        return
    await record_ring(app)


def make_app(*, sender, ring_secret, clients, access, ha_url, ha_token,
             lock_entity, lock_service="unlock", camera_entity="",
             go2rtc_url, stream, open_interval=3.0, visitor_entity="",
             visitor_retry=5.0, history=None):
    app = web.Application(middlewares=[api_auth])
    app[HISTORY] = history if history is not None else History()
    app[SENDER] = sender
    app[RING_SECRET] = ring_secret
    app[CLIENTS] = clients
    app[ACCESS] = access
    app[GO2RTC] = go2rtc_url
    app[STREAM] = stream
    app[LAST_OPEN] = [0.0]
    app[OPEN_INTERVAL] = open_interval

    async def session_ctx(app):
        session = ClientSession(timeout=ClientTimeout(total=10))
        app[SESSION] = session
        app[HA] = HomeAssistant(session, ha_url, ha_token, lock_entity,
                                lock_service, camera_entity)
        watcher = None
        if visitor_entity:
            watcher = asyncio.create_task(watch_visitor(
                session, ha_url, ha_token, visitor_entity,
                lambda: ring_from_visitor(app), visitor_retry))
        yield
        if watcher is not None:
            watcher.cancel()
            try:
                await watcher
            except asyncio.CancelledError:
                pass
        await session.close()

    app.cleanup_ctx.append(session_ctx)
    app.router.add_get("/health", health)
    app.router.add_post("/ring", ring)
    app.router.add_get("/api/state", state)
    app.router.add_post("/api/open", open_door)
    app.router.add_post("/api/answered", answered)
    app.router.add_get("/api/history", history_list)
    app.router.add_get("/api/history/{id}/picture", history_picture)
    app.router.add_get("/api/snapshot", snapshot)
    app.router.add_get("/api/ws", signaling)
    return app


def build(cfg, *, token_provider=None, fcm_endpoint=None):
    """The app from config.json's settings (see config.example.json).
    Exits with a message naming what is missing or wrong."""
    def section(name):
        value = cfg.get(name) or {}
        if not isinstance(value, dict):
            raise SystemExit(f"config: {name} must be an object")
        return value

    def need(name, key):
        value = section(name).get(key)
        if value in (None, ""):
            raise SystemExit(f"config: {name}.{key} is missing")
        return value

    push, ha = section("push"), section("home_assistant")
    secret = str(need("push", "ring_secret"))
    if len(secret) < 16:
        raise SystemExit("config: push.ring_secret needs 16+ characters")
    lock_service = ha.get("lock_service", "unlock")
    if lock_service not in ("unlock", "open"):
        raise SystemExit("config: home_assistant.lock_service must be "
                         "unlock or open")
    try:
        clients = Clients(cfg.get("phones") or [])
    except ValueError as exc:
        raise SystemExit(f"config: phones: {exc}") from exc
    if not clients:
        raise SystemExit("config: no phones")
    cf = section("cloudflare")
    team, aud = cf.get("team_domain", ""), cf.get("aud", "")
    access = AccessJwt(team, aud) if team and aud else None
    if access is None:
        log.warning("cloudflare.team_domain/aud not set: only the service "
                    "token headers are checked")
    sender = Sender(
        project_id=need("push", "fcm_project_id"),
        token_provider=token_provider or google_token_provider(
            need("push", "firebase_key")),
        topic=push.get("topic", "doorbell"),
        debounce_seconds=float(push.get("debounce_seconds", 10)),
        endpoint=fcm_endpoint,
    )
    return make_app(
        sender=sender, ring_secret=secret, clients=clients, access=access,
        ha_url=need("home_assistant", "url"),
        ha_token=need("home_assistant", "token"),
        lock_entity=need("home_assistant", "lock"),
        lock_service=lock_service,
        camera_entity=ha.get("camera", ""),
        go2rtc_url=need("go2rtc", "url"), stream=need("go2rtc", "stream"),
        open_interval=float(ha.get("open_interval_seconds", 3)),
        visitor_entity=ha.get("visitor", ""),
        history=History(cfg.get("history_dir", "")),
    )


def main():
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    env = os.environ
    path = env.get("CONFIG_FILE", "/srv/doorbell/config.json")
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    log.info("config: %s", path)
    app = build(cfg, fcm_endpoint=env.get("FCM_ENDPOINT"))
    log.info("%d phone(s) allowed", len(app[CLIENTS]))
    web.run_app(app, port=int(cfg.get("port", 8099)), access_log=None)


if __name__ == "__main__":
    main()
