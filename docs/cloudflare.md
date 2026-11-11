# Cloudflare setup

How the phones reach the server from anywhere: a Cloudflare Tunnel publishes
the server under your hostname, and Cloudflare Access lets through only
requests that carry one of your phones' service tokens. Everything below is
in the Zero Trust dashboard (one.dash.cloudflare.com); menu names are those
of late 2026 and may move.

You need a domain on Cloudflare. The examples use `doorbell.example.com` and
the team `example.cloudflareaccess.com`.

## 1. Team domain

Zero Trust -> **Settings** -> **Team name and domain**. Note the domain, e.g.
`example.cloudflareaccess.com`: it is `cloudflare.team_domain` in the
server's config.

## 2. Tunnel

1. **Networks** -> **Connectors** -> **Cloudflare Tunnels** -> **Create a
   tunnel** -> *Cloudflared*. Name it, then run the connector it shows (a
   `cloudflared` container on the same Docker network as the server is the
   simplest).
2. **Public hostname**: subdomain `doorbell`, your domain, service
   `http://doorbell-server:8099` (or your reverse proxy in front of it).

Nothing else is published: the WebRTC media does not go through the tunnel
(see step 6).

## 3. Service tokens, one per phone

**Access controls** -> **Service credentials** -> **Service Tokens** ->
**Create Service Token**.

- Name: the phone, e.g. `phone1`.
- Duration: **Non-expiring** (a phone that suddenly gets 403 is worse than a
  token you revoke by hand).
- Copy the **Client ID** and **Client Secret** now: the secret is shown only
  once.

Repeat for each phone. A lost phone: revoke its token here and remove its
entry from the server's `phones`.

## 4. Access application

**Access controls** -> **Applications** -> **Add an application** ->
**Self-hosted**.

1. Name: `Doorbell`. Destination: public hostname `doorbell.example.com`
   (the one from step 2).
2. Policy: **Create new policy**, name `Doorbell phones`, **Action: Service
   Auth**. Include: **Service Token** -> select the phones' tokens. Service
   Auth is what makes Access accept the token headers instead of showing a
   login page; with *Allow* the app gets a redirect to the login page.
3. Save. Open the application again: its **Application Audience (AUD) Tag**
   (under Basic information / Overview) is `cloudflare.aud` in the server's
   config.

## 5. Server config

```json
"cloudflare": {
  "team_domain": "example.cloudflareaccess.com",
  "aud": "the AUD tag from step 4"
},
"phones": [
  {"name": "phone1", "client_id": "<Client ID>", "client_secret": "<Client Secret>"}
]
```

Restart the server. Through Cloudflare it checks the JWT Access adds
(`Cf-Access-Jwt-Assertion`, signed for this AUD) and maps it to the phone's
name; requests that reach it directly on the LAN are checked against the
token headers themselves.

## 6. WebRTC media

Signaling goes through the tunnel; the video and audio go straight between
the phone and go2rtc (port 8555, TCP and UDP). Away from home that port has
to be reachable: forward it on the router, and list the public address in
go2rtc's `webrtc.candidates` (e.g. `stun:8555`, or `your.public.ip:8555`).

## 7. Check

```sh
# 403 from Cloudflare: no token
curl -i https://doorbell.example.com/api/state
# 200 and the lock state
curl -H "CF-Access-Client-Id: <Client ID>" \
     -H "CF-Access-Client-Secret: <Client Secret>" \
     https://doorbell.example.com/api/state
```

A 401 with a valid token means the server does not know that phone: its
`client_id` is missing from `phones`, or `aud` does not match the
application.

## Optional: at home without Cloudflare

If your LAN DNS resolves the hostname straight to the server (or the proxy
in front of it), the app keeps working at home without internet, except for
the push itself. The server accepts the same token headers there.
