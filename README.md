# open-video-doorbell

An Android app that rings like an incoming video call when the doorbell is
pressed, shows the live doorbell video (Frigate's go2rtc), can talk back
through the doorbell's speaker, and opens the door lock through Home
Assistant. Built because the Reolink app has no button for the lock.

```
doorbell press
  -> Home Assistant: binary_sensor.<doorbell>_visitor turns on
  -> server/ (this repo, on the LAN) sees it over HA's websocket
  -> FCM data message to the `doorbell` topic
  -> phones ring: full-screen call with a snapshot of the door,
     Dismiss / Unlock / Answer (also on the lock screen)
  -> Answer: live video + microphone on (two-way audio)
  -> Unlock, or hold Open on the door page: the server opens the lock
```

The phones talk only to the server. It holds the Home Assistant token, the
lock, the camera stream and the list of phones; a phone holds the server's
URL and its own Cloudflare Access service token.

**Setting it up:** [docs/setup.md](docs/setup.md) walks through everything
outside this repo (go2rtc, Home Assistant, Firebase, the server, Cloudflare,
building and installing the app) and what to check when something does not
work.

## Server (`server/`)

Python (aiohttp), one container. Endpoints:

- `POST /ring` with `X-Secret`: ring now (tests; the Visitor sensor is
  watched without it).
- `GET /api/state`, `POST /api/open`, `GET /api/snapshot`, `GET /api/ws`
  (go2rtc's WebRTC signaling, relayed for the configured stream only; the
  media goes straight between the phone and go2rtc's port 8555).
- `POST /api/answered`: this phone took the ring; the others get a push to
  stop ringing ("Answered by phone1").
- `GET /api/history`, `GET /api/history/<id>/picture`: the last 100 rings
  with the picture taken at each, who answered and who opened.
- `GET /api/app`, `GET /api/app/apk`: the newest app in `app_dir`, for
  the app's own updates.

Who may use `/api`: the `phones` in the config, each with its own
Cloudflare Access service token. Through Cloudflare the server checks the
JWT Access adds (`aud`); at home, where the LAN DNS sends the name straight
to the server, it checks the token headers itself. So the app works without
internet at home (except for the push). Every door opening is logged with
the phone's name; at most one per 3 seconds.

Configuration: one JSON file, `CONFIG_FILE` (default
`/srv/doorbell/config.json`), like `server/config.example.json`. A change is
an edit and a restart.

| Key | |
|---|---|
| `port` | listen port, default 8099 |
| `history_dir` | ring history with its pictures, writable; empty: in memory only |
| `app_dir` | optional: where the APKs the phones update from are, named `doorbell-<version code>.apk` |
| `push.fcm_project_id`, `push.firebase_key` | Firebase project and the path of its service-account key |
| `push.ring_secret` | `X-Secret` for `POST /ring`, 16+ characters |
| `push.topic`, `push.debounce_seconds` | optional: `doorbell`; a second press within 10 s is ignored |
| `home_assistant.url`, `.token` | Home Assistant and a non-admin, local-only user's token (it reads states, calls the lock, subscribes to state changes) |
| `home_assistant.lock` | the lock entity |
| `home_assistant.lock_service` | optional: `unlock` (default) or `open` for a latch |
| `home_assistant.visitor` | the doorbell's Visitor binary_sensor; the server rings when it turns on |
| `home_assistant.camera` | optional: snapshots from Home Assistant instead of go2rtc |
| `home_assistant.open_interval_seconds` | optional: at most one opening per 3 s |
| `go2rtc.url`, `go2rtc.stream` | the stream with the camera's two-way audio in a codec WebRTC plays (Opus) |
| `cloudflare.team_domain`, `.aud` | with both set, Access JWTs are checked |
| `phones` | `[{name, client_id, client_secret}]`, one per phone; the name is what the others see ("Answered by phone1") |

`FCM_ENDPOINT` in the environment overrides FCM, for tests only.

Tests (fake Home Assistant, go2rtc and FCM; test-signed JWTs):

```sh
pip install -r server/requirements.txt
python -m unittest server/test_server.py -v
```

## Cloudflare Access

A tunnel publishes the server; an Access application with a **Service Auth**
policy lets through only the phones' service tokens, one per phone. Step by
step, with the server config it produces: [docs/cloudflare.md](docs/cloudflare.md).

## App

Flutter, Android only. To build it you need your own Firebase project: its
`google-services.json` in `android/app/` and your application id in
`android/local.properties` (`doorbell.applicationId=...`, the package name
registered in Firebase); both stay out of git. Then:

```sh
flutter pub get
flutter build apk --release --dart-define-from-file=phones/phone1.json
```

`phones/phone1.json` holds `DOORBELL_SERVER_URL`, `DOORBELL_CF_CLIENT_ID`
and `DOORBELL_CF_CLIENT_SECRET`, built into that phone's APK; without it the
app asks for them in Settings. Details and the first run on each phone:
[docs/setup.md](docs/setup.md#6-build-the-app).

`third_party/flutter_callkit_incoming` is the call plugin with the Unlock
button, the live preview and a few fixes (see `third_party/README.md`).
`tool/render_icon.py` renders the launcher icon's PNGs from its vector.

### Updates

The app updates itself from the server: when `app_dir` holds a newer
`doorbell-<version code>.apk` than the installed one, the main page shows
**Update**; it downloads the APK and hands it to Android's installer. The
first time Android asks to allow installs from Doorbell and to confirm; on
Android 12+ later updates go through without asking. Samsung's Auto Blocker
refuses them: turn it off for the update.

To publish one, build it without per-phone settings (the phones keep theirs)
and with a growing version code, signed with the same key as the installed
app:

```sh
flutter build apk --release --target-platform android-arm64 \n  --build-number=<n> --build-name=<date>
cp build/app/outputs/flutter-apk/app-release.apk <app_dir>/doorbell-<n>.apk
```

A date like `yyDDDHHmm` (year, day of the year, time) makes a good `<n>`;
`<date>`, e.g. `2026.11.11-1924`, is what Settings shows as the version.

## Choices and limits

- **Data-only push.** No `notification` block, or the system would show it
  itself and the call screen would never appear. The call shows how long the
  push took ("push 0.8 s").
- **Answering does not need the phone unlocked**, like any call: the app
  shows over the lock screen for that call only. Opening the door, the
  history and Settings ask for the phone's own unlock (PIN, fingerprint)
  first, on the call screen, in the notification and in the app.
- **Live video is WebRTC from go2rtc**, the stream in the config: it needs
  the camera's two-way audio and audio WebRTC plays (Opus; a stream with
  only AAC has no sound). Until the first frame arrives, the snapshot is
  shown.
- **Before answering** the call screen shows the snapshot, then live video
  (no audio) once it starts.
- **Away from home** the signaling goes through Cloudflare and the media to
  go2rtc's port 8555, which must be reachable from outside.
- **Foreground only.** Video and microphone stop when the app goes to the
  background; End closes the app.
- **Android only.**

## Credits

- Built with [Claude Code](https://claude.com/claude-code).
- [flutter_callkit_incoming](https://github.com/hiennguyen92/flutter_callkit_incoming)
  by Hien Nguyen: the call screen, vendored with patches.
- [go2rtc](https://github.com/AlexxIT/go2rtc): the camera's WebRTC stream and
  two-way audio.

## License

MIT, see [LICENSE](LICENSE). `third_party/flutter_callkit_incoming` keeps its
own MIT license.
