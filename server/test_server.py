"""End-to-end tests of the server against fake Home Assistant, go2rtc and
FCM endpoints served locally. The Google token step is a stub; the Access
JWTs are signed with a test key.

Run from the repo root (needs requirements.txt):
  python -m unittest server/test_server.py -v
"""

import asyncio
import json
import os
import sys
import time
import unittest

import jwt
from aiohttp import WSMsgType, web
from aiohttp.test_utils import TestClient, TestServer
from cryptography.hazmat.primitives.asymmetric import rsa

sys.path.insert(0, os.path.dirname(__file__))
import app  # noqa: E402

SECRET = "s" * 20
PHONE = {"name": "phone1", "client_id": "abc.access",
         "client_secret": "phone-secret"}
PHONE_HEADERS = {"CF-Access-Client-Id": PHONE["client_id"],
                 "CF-Access-Client-Secret": PHONE["client_secret"]}
TEAM = "example.cloudflareaccess.com"
AUD = "aud-tag"
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class FakeKeys:
    """Stands in for PyJWKClient: always the test key."""

    class _Key:
        key = KEY.public_key()

    def get_signing_key_from_jwt(self, _token):
        return self._Key()


def access_jwt(client_id=PHONE["client_id"], aud=AUD, key=KEY):
    now = int(time.time())
    return jwt.encode(
        {"common_name": client_id, "aud": [aud], "iss": f"https://{TEAM}",
         "iat": now, "exp": now + 300},
        key, algorithm="RS256")


def fake_home_assistant(calls, status):
    def check(request):
        assert request.headers["Authorization"] == "Bearer ha-token"

    async def states(request):
        check(request)
        if status["code"] != 200:
            return web.Response(status=status["code"])
        return web.json_response(
            {"entity_id": request.match_info["entity"], "state": "locked",
             "attributes": {"friendly_name": "Front gate"}})

    async def service(request):
        check(request)
        calls.append((request.match_info["service"], await request.json()))
        return web.json_response([], status=status["code"])

    async def camera(request):
        check(request)
        return web.Response(
            body=b"ha:" + request.match_info["entity"].encode(),
            content_type="image/jpeg")

    ha = web.Application()
    ha.router.add_get("/api/states/{entity}", states)
    ha.router.add_post("/api/services/lock/{service}", service)
    ha.router.add_get("/api/camera_proxy/{entity}", camera)
    return ha


def fake_go2rtc():
    async def frame(request):
        return web.Response(body=b"frame:" + request.query["src"].encode(),
                            content_type="image/jpeg")

    async def ws(request):
        sock = web.WebSocketResponse()
        await sock.prepare(request)
        async for msg in sock:
            if msg.type == WSMsgType.TEXT:
                await sock.send_json(
                    {"type": "echo", "value": msg.data,
                     "src": request.query["src"]})
        return sock

    go = web.Application()
    go.router.add_get("/api/frame.jpeg", frame)
    go.router.add_get("/api/ws", ws)
    return go


def fake_fcm(sent):
    async def send(request):
        sent.append({"auth": request.headers.get("Authorization"),
                     "json": await request.json()})
        return web.json_response({"name": "projects/p/messages/1"})

    fcm = web.Application()
    fcm.router.add_post("/v1/projects/p/messages:send", send)
    return fcm


class ServerTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.ha_calls, self.ha_status, self.fcm_sent = [], {"code": 200}, []
        self.servers = [TestServer(fake_home_assistant(self.ha_calls,
                                                       self.ha_status)),
                        TestServer(fake_go2rtc()),
                        TestServer(fake_fcm(self.fcm_sent))]
        for s in self.servers:
            await s.start_server()
        ha, go, fcm = self.servers
        self.sender = app.Sender(
            "p", token_provider=lambda: "fake-access", debounce_seconds=0.5,
            endpoint=str(fcm.make_url("/v1/projects/p/messages:send")))
        self.client = await self.make_client()

    async def make_client(self, camera_entity=""):
        ha, go, _ = self.servers
        server_app = app.make_app(
            sender=self.sender, ring_secret=SECRET,
            clients=app.Clients([PHONE]),
            access=app.AccessJwt(TEAM, AUD, jwk_client=FakeKeys()),
            ha_url=str(ha.make_url("")), ha_token="ha-token",
            lock_entity="lock.gate", lock_service="open",
            camera_entity=camera_entity,
            go2rtc_url=str(go.make_url("")), stream="doorbell_sub",
            open_interval=0.3)
        client = TestClient(TestServer(server_app))
        await client.start_server()
        return client

    async def asyncTearDown(self):
        await self.client.close()
        for s in self.servers:
            await s.close()

    # --- /ring --------------------------------------------------------------

    async def test_ring_sends_high_priority_data_message_to_topic(self):
        res = await self.client.post("/ring", headers={"X-Secret": SECRET})
        self.assertEqual((res.status, await res.text()), (200, "rang"))
        self.assertEqual(len(self.fcm_sent), 1)
        self.assertEqual(self.fcm_sent[0]["auth"], "Bearer fake-access")
        message = self.fcm_sent[0]["json"]["message"]
        self.assertEqual(message["topic"], "doorbell")
        self.assertEqual(message["data"]["type"], "doorbell")
        self.assertEqual(message["android"]["priority"], "HIGH")
        sent_at = int(message["data"]["sent_at"])
        self.assertLess(abs(sent_at - time.time() * 1000), 5000)
        self.assertRegex(message["data"]["ring_id"], r"^[0-9a-f]{32}$")
        # A notification block would be shown by the system and never reach
        # the app, so no call screen could appear.
        self.assertNotIn("notification", message)

    async def test_custom_title_and_body(self):
        await self.client.post("/ring", headers={"X-Secret": SECRET},
                               json={"title": "Front door", "body": "Parcel"})
        data = self.fcm_sent[0]["json"]["message"]["data"]
        self.assertEqual((data["title"], data["body"]), ("Front door", "Parcel"))

    async def test_ring_needs_the_secret_not_a_phone(self):
        for headers in ({"X-Secret": "wrong"}, {}, PHONE_HEADERS):
            res = await self.client.post("/ring", headers=headers)
            self.assertEqual(res.status, 401)
        self.assertEqual(self.fcm_sent, [])

    async def test_second_press_is_debounced(self):
        await self.client.post("/ring", headers={"X-Secret": SECRET})
        res = await self.client.post("/ring", headers={"X-Secret": SECRET})
        self.assertIn("ignored", await res.text())
        self.assertEqual(len(self.fcm_sent), 1)

    async def test_bad_ring_bodies(self):
        for body, text in ((b"nope", "invalid json"),
                           (b"[1]", "body must be a json object")):
            res = await self.client.post(
                "/ring", headers={"X-Secret": SECRET}, data=body)
            self.assertEqual((res.status, await res.text()), (400, text))
        self.assertEqual(self.fcm_sent, [])

    async def test_failed_send_does_not_block_the_next_press(self):
        self.sender._token = lambda: (_ for _ in ()).throw(OSError("no net"))
        res = await self.client.post("/ring", headers={"X-Secret": SECRET})
        self.assertEqual(res.status, 502)
        self.sender._token = lambda: "fake-access"
        res = await self.client.post("/ring", headers={"X-Secret": SECRET})
        self.assertEqual(await res.text(), "rang")

    async def test_health(self):
        res = await self.client.get("/health")
        self.assertEqual(await res.text(), "ok")

    # --- who may use /api ---------------------------------------------------

    async def test_api_rejects_unknown_callers(self):
        for headers in ({},
                        {"CF-Access-Client-Id": PHONE["client_id"],
                         "CF-Access-Client-Secret": "wrong"},
                        {"CF-Access-Client-Id": "other.access",
                         "CF-Access-Client-Secret": PHONE["client_secret"]},
                        {"X-Secret": SECRET}):
            res = await self.client.get("/api/state", headers=headers)
            self.assertEqual(res.status, 401, headers)

    async def test_service_token_headers_at_home(self):
        res = await self.client.get("/api/state", headers=PHONE_HEADERS)
        self.assertEqual(await res.json(),
                         {"lock": "locked", "name": "Front gate"})

    async def test_access_jwt_through_cloudflare(self):
        res = await self.client.get(
            "/api/state", headers={"Cf-Access-Jwt-Assertion": access_jwt()})
        self.assertEqual(res.status, 200)

    async def test_bad_access_jwts(self):
        for token in (access_jwt(client_id="other.access"),  # not in the list
                      access_jwt(aud="another-app"),
                      access_jwt(key=OTHER_KEY),
                      "garbage"):
            res = await self.client.get(
                "/api/state", headers={"Cf-Access-Jwt-Assertion": token})
            self.assertEqual(res.status, 401)

    async def test_a_jwt_is_checked_even_with_good_headers(self):
        headers = dict(PHONE_HEADERS,
                       **{"Cf-Access-Jwt-Assertion": access_jwt(key=OTHER_KEY)})
        res = await self.client.get("/api/state", headers=headers)
        self.assertEqual(res.status, 401)

    # --- lock ---------------------------------------------------------------

    async def test_state_reports_home_assistant_errors(self):
        self.ha_status["code"] = 401
        res = await self.client.get("/api/state", headers=PHONE_HEADERS)
        self.assertEqual(res.status, 502)
        self.assertIn("rejected", (await res.json())["error"])

    async def test_open_calls_the_configured_service(self):
        res = await self.client.post("/api/open", headers=PHONE_HEADERS)
        self.assertEqual(await res.json(), {"ok": True})
        self.assertEqual(self.ha_calls, [("open", {"entity_id": "lock.gate"})])

    async def test_open_at_most_once_per_interval(self):
        await self.client.post("/api/open", headers=PHONE_HEADERS)
        res = await self.client.post("/api/open", headers=PHONE_HEADERS)
        self.assertEqual(res.status, 429)
        self.assertEqual(len(self.ha_calls), 1)

    async def test_failed_open_does_not_block_the_next(self):
        self.ha_status["code"] = 500
        res = await self.client.post("/api/open", headers=PHONE_HEADERS)
        self.assertEqual(res.status, 502)
        self.ha_status["code"] = 200
        res = await self.client.post("/api/open", headers=PHONE_HEADERS)
        self.assertEqual(res.status, 200)

    async def test_open_needs_a_phone(self):
        res = await self.client.post("/api/open")
        self.assertEqual(res.status, 401)
        self.assertEqual(self.ha_calls, [])

    # --- answered ----------------------------------------------------------

    async def test_answered_tells_the_other_phones(self):
        res = await self.client.post("/api/answered", headers=PHONE_HEADERS,
                                     json={"ring_id": "abc123"})
        self.assertEqual(await res.json(), {"ok": True})
        message = self.fcm_sent[0]["json"]["message"]
        self.assertEqual(message["topic"], "doorbell")
        self.assertEqual(message["data"], {
            "type": "doorbell_answered", "ring_id": "abc123",
            "by": "phone1"})
        self.assertEqual(message["android"]["priority"], "HIGH")

    async def test_answered_needs_a_phone_and_a_ring_id(self):
        res = await self.client.post("/api/answered", json={"ring_id": "x"})
        self.assertEqual(res.status, 401)
        res = await self.client.post("/api/answered", headers=PHONE_HEADERS,
                                     json={})
        self.assertEqual(res.status, 400)
        self.assertEqual(self.fcm_sent, [])

    # --- history ------------------------------------------------------------

    async def test_a_ring_answered_and_opened_is_one_entry(self):
        await self.client.post("/ring", headers={"X-Secret": SECRET})
        ring_id = self.fcm_sent[0]["json"]["message"]["data"]["ring_id"]
        await self.client.post("/api/answered", headers=PHONE_HEADERS,
                               json={"ring_id": ring_id})
        await self.client.post("/api/open", headers=PHONE_HEADERS)

        res = await self.client.get("/api/history", headers=PHONE_HEADERS)
        (entry,) = (await res.json())["entries"]
        self.assertEqual(entry["id"], ring_id)
        self.assertEqual(entry["kind"], "ring")
        self.assertEqual(entry["answered_by"], "phone1")
        self.assertEqual(entry["opened_by"], "phone1")
        self.assertTrue(entry["picture"])

        res = await self.client.get(f"/api/history/{ring_id}/picture",
                                    headers=PHONE_HEADERS)
        self.assertEqual(await res.read(), b"frame:doorbell_sub")

    async def test_an_opening_with_no_ring_is_its_own_entry(self):
        await self.client.post("/api/open", headers=PHONE_HEADERS)
        res = await self.client.get("/api/history", headers=PHONE_HEADERS)
        (entry,) = (await res.json())["entries"]
        self.assertEqual((entry["kind"], entry["by"]), ("open", "phone1"))

    async def test_history_needs_a_phone(self):
        res = await self.client.get("/api/history")
        self.assertEqual(res.status, 401)
        res = await self.client.get("/api/history/../../etc/picture",
                                    headers=PHONE_HEADERS)
        self.assertEqual(res.status, 404)

    # --- app updates --------------------------------------------------------

    async def test_serves_the_newest_apk_to_phones(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            for code, body in ((9, b"old"), (26111219, b"new")):
                with open(os.path.join(d, f"doorbell-{code}.apk"), "wb") as f:
                    f.write(body)
            self.client.server.app[app.APP_DIR] = d
            res = await self.client.get("/api/app")
            self.assertEqual(res.status, 401)
            res = await self.client.get("/api/app", headers=PHONE_HEADERS)
            self.assertEqual(await res.json(), {"version": 26111219})
            res = await self.client.get("/api/app/apk", headers=PHONE_HEADERS)
            self.assertEqual(await res.read(), b"new")
            self.assertEqual(res.headers["Content-Type"],
                             "application/vnd.android.package-archive")

    async def test_no_app_published(self):
        res = await self.client.get("/api/app", headers=PHONE_HEADERS)
        self.assertEqual(res.status, 404)

    # --- picture and video --------------------------------------------------

    async def test_snapshot_from_go2rtc(self):
        res = await self.client.get("/api/snapshot", headers=PHONE_HEADERS)
        self.assertEqual(await res.read(), b"frame:doorbell_sub")
        self.assertEqual(res.headers["Cache-Control"], "no-store")

    async def test_snapshot_from_the_camera_entity(self):
        await self.client.close()
        self.client = await self.make_client(camera_entity="camera.doorbell")
        res = await self.client.get("/api/snapshot", headers=PHONE_HEADERS)
        self.assertEqual(await res.read(), b"ha:camera.doorbell")

    async def test_signaling_is_relayed_for_the_configured_stream_only(self):
        sock = await self.client.ws_connect(
            "/api/ws?src=front_yard_main&kind=view", headers=PHONE_HEADERS)
        await sock.send_str('{"type":"webrtc/offer","value":"v=0"}')
        reply = json.loads((await sock.receive()).data)
        self.assertEqual(reply["type"], "echo")
        self.assertEqual(reply["value"], '{"type":"webrtc/offer","value":"v=0"}')
        self.assertEqual(reply["src"], "doorbell_sub")
        await sock.close()

    async def test_signaling_needs_a_phone(self):
        res = await self.client.get("/api/ws")
        self.assertEqual(res.status, 401)


def state_event(entity, old, new):
    return {"id": 1, "type": "event", "event": {
        "event_type": "state_changed",
        "data": {"entity_id": entity,
                 "old_state": {"state": old} if old else None,
                 "new_state": {"state": new}}}}


class VisitorWatchTest(unittest.IsolatedAsyncioTestCase):
    """The server rings by itself from Home Assistant's websocket."""

    async def asyncSetUp(self):
        self.connections = 0
        self.events = []
        self.fcm_sent = []

        async def websocket(request):
            self.connections += 1
            sock = web.WebSocketResponse()
            await sock.prepare(request)
            await sock.send_json({"type": "auth_required"})
            auth = await sock.receive_json()
            if auth.get("access_token") != "ha-token":
                await sock.send_json({"type": "auth_invalid"})
                await sock.close()
                return sock
            await sock.send_json({"type": "auth_ok"})
            sub = await sock.receive_json()
            assert sub["type"] == "subscribe_events"
            assert sub["event_type"] == "state_changed"
            await sock.send_json({"id": 1, "type": "result", "success": True})
            # Like HA, events are not replayed to a new connection.
            for ev in self.events if self.connections == 1 else []:
                await sock.send_json(ev)
            # The first connection drops after its events, to test reconnects.
            await sock.close()
            return sock

        ha = web.Application()
        ha.router.add_get("/api/websocket", websocket)
        self.ha = TestServer(ha)
        self.fcm = TestServer(fake_fcm(self.fcm_sent))
        await self.ha.start_server()
        await self.fcm.start_server()

    async def asyncTearDown(self):
        await self.ha.close()
        await self.fcm.close()

    async def run_server(self, token="ha-token", seconds=0.6):
        sender = app.Sender(
            "p", token_provider=lambda: "fake-access", debounce_seconds=0,
            endpoint=str(self.fcm.make_url("/v1/projects/p/messages:send")))
        server_app = app.make_app(
            sender=sender, ring_secret=SECRET, clients=app.Clients([PHONE]),
            access=None, ha_url=str(self.ha.make_url("")), ha_token=token,
            lock_entity="lock.gate", go2rtc_url="http://unused",
            stream="doorbell_sub",
            visitor_entity="binary_sensor.doorbell_visitor",
            visitor_retry=0.2)
        client = TestClient(TestServer(server_app))
        await client.start_server()
        await asyncio.sleep(seconds)
        await client.close()

    async def test_rings_when_the_visitor_sensor_turns_on(self):
        v = "binary_sensor.doorbell_visitor"
        self.events = [state_event("binary_sensor.other", "off", "on"),
                       state_event(v, "off", "on"),
                       state_event(v, "on", "on"),  # attribute change
                       state_event(v, "on", "off")]
        await self.run_server(seconds=0.4)
        self.assertEqual(len(self.fcm_sent), 1)
        self.assertEqual(
            self.fcm_sent[0]["json"]["message"]["data"]["type"], "doorbell")

    async def test_reconnects_after_a_drop(self):
        await self.run_server(seconds=0.6)
        self.assertGreaterEqual(self.connections, 2)

    async def test_bad_token_retries_without_ringing(self):
        self.events = [state_event("binary_sensor.doorbell_visitor",
                                   "off", "on")]
        await self.run_server(token="wrong", seconds=0.5)
        self.assertGreaterEqual(self.connections, 2)
        self.assertEqual(self.fcm_sent, [])


class HistoryTest(unittest.TestCase):
    def test_kept_on_disk_and_pruned(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            h = app.History(d, keep=2)
            ids = ["a" * 32, "b" * 32, "c" * 32]
            for n, ring_id in enumerate(ids):
                h.add_ring(ring_id, 1000.0 + n)
                h.set_picture(ring_id, ring_id.encode())
            again = app.History(d, keep=2)
            self.assertEqual([e["id"] for e in again.entries()], ids[:0:-1])
            self.assertEqual(again.picture("c" * 32), b"c" * 32)
            self.assertIsNone(again.picture("a" * 32))  # pruned
            self.assertFalse(os.path.exists(os.path.join(d, "a" * 32 + ".jpg")))

    def test_late_opening_is_not_the_ring_s(self):
        h = app.History(attach_seconds=300)
        h.add_ring("a" * 32, 1000.0)
        h.opened("phone1", 1000.0 + 301)
        entries = h.entries()
        self.assertEqual([e["kind"] for e in entries], ["open", "ring"])
        self.assertIsNone(entries[1]["opened_by"])

    def test_answered_once(self):
        h = app.History()
        h.add_ring("a" * 32, 1000.0)
        h.answered("a" * 32, "phone1")
        h.answered("a" * 32, "phone2")
        self.assertEqual(h.entries()[0]["answered_by"], "phone1")


class ConfigTest(unittest.TestCase):
    EXAMPLE = os.path.join(os.path.dirname(__file__), "config.example.json")

    def example(self):
        with open(self.EXAMPLE, encoding="utf-8") as f:
            return json.load(f)

    def test_the_example_builds(self):
        cfg = self.example()
        cfg["history_dir"] = ""
        server_app = app.build(cfg, token_provider=lambda: "t")
        self.assertEqual(len(server_app[app.CLIENTS]), 2)
        self.assertEqual(server_app[app.STREAM], "doorbell_main")
        self.assertIsNotNone(server_app[app.ACCESS])

    def test_says_what_is_missing(self):
        cfg = self.example()
        del cfg["home_assistant"]["lock"]
        with self.assertRaisesRegex(SystemExit, "home_assistant.lock"):
            app.build(cfg, token_provider=lambda: "t")
        cfg = self.example()
        cfg["phones"] = []
        with self.assertRaisesRegex(SystemExit, "no phones"):
            app.build(cfg, token_provider=lambda: "t")
        cfg = self.example()
        cfg["push"]["ring_secret"] = "short"
        with self.assertRaisesRegex(SystemExit, "16"):
            app.build(cfg, token_provider=lambda: "t")


class ClientsTest(unittest.TestCase):
    def test_entries_need_all_fields(self):
        with self.assertRaises(ValueError):
            app.Clients([{"name": "x", "client_id": "y"}])

    def test_go2rtc_urls(self):
        self.assertEqual(
            app.go2rtc_url("http://go2rtc:1984/", "/api/ws", "a b", "ws"),
            "ws://go2rtc:1984/api/ws?src=a+b")
        self.assertEqual(
            app.go2rtc_url("https://x/live/webrtc", "/api/ws", "d", "ws"),
            "wss://x/live/webrtc/api/ws?src=d")
        self.assertEqual(
            app.go2rtc_url("http://go2rtc:1984", "/api/frame.jpeg", "d"),
            "http://go2rtc:1984/api/frame.jpeg?src=d")


if __name__ == "__main__":
    unittest.main()
