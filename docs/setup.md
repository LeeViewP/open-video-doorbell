# Setup, from zero to a ringing phone

Everything that has to exist outside this repo, in order. Expect an evening.
You should be comfortable with Docker, editing YAML/JSON and a terminal.

What you end up with:

```
doorbell press -> Home Assistant (Visitor sensor) -> doorbell-server -> Firebase push
-> phones ring -> app talks to doorbell-server (behind Cloudflare Access)
-> live video and talk-back from go2rtc, door opened through Home Assistant
```

## 0. What you need

- **Home Assistant** with your doorbell (it must have a "visitor"/"pressed"
  `binary_sensor`; the Reolink integration creates
  `binary_sensor.<doorbell>_visitor`) and the door lock as a `lock` entity.
- **go2rtc** reachable from the server: standalone, or the one inside Frigate
  (port 1984).
- **A Docker host** on the same LAN for the server.
- **A domain on Cloudflare** (free plan is enough) for remote access.
- **A Firebase account** (free Spark plan).
- To build the app: **Flutter SDK** (stable, 3.35+), **JDK 17**, the
  **Android SDK** (Android Studio installs it), and `adb`.
- One or more **Android phones**.

## 1. go2rtc stream

The app plays one go2rtc stream: video, the camera's audio in a codec WebRTC
plays (Opus), and the camera's two-way audio for talking back. Most cameras
send AAC, so add an Opus copy with ffmpeg. Example for a Reolink doorbell:

```yaml
streams:
  doorbell_main:
    - rtsp://USER:PASS@DOORBELL-IP:554/h264Preview_01_main
    - ffmpeg:doorbell_main#audio=opus
webrtc:
  candidates:
    - stun:8555          # lets go2rtc find its public address
```

- Check it in go2rtc's web UI (`http://GO2RTC:1984`) -> the stream -> *webrtc*:
  you should see and hear the door.
- Talk-back depends on the camera supporting two-way audio in go2rtc; see the
  go2rtc README for your model.
- Port **8555 (TCP and UDP)** carries the media. Away from home the phone
  connects to it directly, so forward 8555 on your router to the go2rtc host.

## 2. Home Assistant user and token

The server needs a token that can read states, call the lock and subscribe to
events. Give it its own user, not yours:

1. Settings -> People -> **Add person**, name `Doorbell server`, *Allow
   login* on, **Administrator off**, **Can only log in from the local
   network** on. Set a password.
2. Log in as that user (a private browser window) -> click the user name
   (bottom left) -> **Security** -> **Long-lived access tokens** -> Create.
   Copy the token; it is shown once.
3. Note the entity ids: the lock (e.g. `lock.front_gate`) and the visitor
   sensor (Developer tools -> States, search `visitor`).

If your lock opens a latch with `lock.open` instead of `lock.unlock`, set
`lock_service` to `open` in the config.

## 3. Firebase

1. console.firebase.google.com -> **Add project** (Analytics not needed).
2. Pick the app's **application id**, a reverse domain you own or any unique
   name, e.g. `com.yourname.doorbell`. It cannot be changed later without
   reinstalling the app.
3. Project overview -> **Add app** -> Android -> package name = that
   application id -> Register -> **download `google-services.json`**. Skip
   the SDK steps (the project already has them).
4. Project settings (gear) -> **Service accounts** -> **Generate new private
   key** -> save it as `firebase-key.json`. This is for the server; keep it
   private.
5. Project settings -> General: note the **Project ID**.

Cloud Messaging (HTTP v1) is on by default for new projects. If pushes fail
with 403, enable *Firebase Cloud Messaging API* in Google Cloud console for
the project.

## 4. Server

On the Docker host, next to a copy of this repo's `server/` folder:

```sh
cp docker-compose.example.yaml docker-compose.yaml
cp config.example.json config.json
# put firebase-key.json here too
chmod 644 config.json firebase-key.json
openssl rand -hex 24      # a ring_secret
```

Fill in `config.json` (every key is described in the README):

- `push.fcm_project_id`: the Firebase Project ID; `push.ring_secret`: the
  random string.
- `home_assistant`: URL as the container sees it, the token, the lock and the
  visitor sensor.
- `go2rtc`: URL as the container sees it (e.g. `http://frigate:1984`) and
  the stream name.
- `cloudflare` and `phones`: filled in step 5; leave them for now with one
  dummy phone so the server starts.

Then `docker compose up -d --build` and check the log
(`docker logs doorbell-server`):

```
config: /srv/doorbell/config.json
1 phone(s) allowed
watching binary_sensor.doorbell_visitor
```

If Home Assistant or go2rtc run in Docker, put the server on the same Docker
network so it can use their container names.

## 5. Cloudflare

Tunnel, one service token per phone, an Access application with a Service Auth
policy: [cloudflare.md](cloudflare.md). It ends with the `cloudflare` and
`phones` parts of `config.json`; restart the server after filling them in
(`docker restart doorbell-server`).

## 6. Build the app

In your clone of this repo:

1. `android/app/google-services.json`: the file from step 3.
2. `android/local.properties` (created by Flutter on the first build, or make
   it): add your application id, the one registered in Firebase:

   ```properties
   doorbell.applicationId=com.yourname.doorbell
   ```

3. One settings file per phone in `phones/` (ignored by git), e.g.
   `phones/phone1.json`:

   ```json
   {
     "DOORBELL_SERVER_URL": "https://doorbell.example.com",
     "DOORBELL_CF_CLIENT_ID": "<phone1's Client ID>",
     "DOORBELL_CF_CLIENT_SECRET": "<phone1's Client Secret>"
   }
   ```

   Without it, enter the same three values in the app's Settings.

4. Build:

   ```sh
   flutter pub get
   flutter build apk --release --dart-define-from-file=phones/phone1.json
   ```

   The APK is `build/app/outputs/flutter-apk/app-release.apk`. Release builds
   are signed with your machine's debug key (`~/.android/debug.keystore`):
   build updates on the same machine, or keep that file, or Android refuses to
   install them over the old app.

## 7. Install on each phone

- USB: enable Developer options (tap *Build number* 7 times) -> **USB
  debugging**, then `adb install -r app-release.apk`.
- Or send the APK and open it on the phone, allowing installs from that app.
- Samsung **Auto Blocker** blocks both: turn it off for the install, back on
  after.

First start on each phone:

1. Allow notifications and **full-screen notifications** (Android 14+; without
   it the call is only a banner on the lock screen).
2. Settings -> Apps -> Doorbell -> Battery -> **Unrestricted** (Samsung and
   others may otherwise delay the push). With Do Not Disturb, add Doorbell to
   its exceptions.
3. The microphone permission is asked the first time you talk.
4. Settings in the app -> **Test connection**: it reads the lock state and
   does not touch the lock.

## 8. Test

Ring without pressing the doorbell (from the LAN):

```sh
curl -X POST -H "X-Secret: <ring_secret>" http://DOCKER-HOST:8099/ring
```

All phones should ring within a couple of seconds, with the door's picture,
then live video. Then press the real doorbell.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Server exits at start | its log: it names the missing or wrong config key |
| `/ring` works, the doorbell does not | the `visitor` entity id; the log says `watching ...` and logs each press |
| No ring on a phone | step 7 permissions and battery; the phone needs internet for Firebase |
| App: "Cloudflare Access refused" | the phone's token is not in the Access policy, or the URL is wrong |
| App: "does not know this phone" (401) | its `client_id` is not in `phones`, or `cloudflare.aud` is wrong |
| Picture but no live video away from home | port 8555 forwarded? `webrtc.candidates` in go2rtc |
| Video but no sound | the stream has no Opus audio (step 1) |
| Opening the door fails | the Home Assistant user may not call that lock; `lock_service` |
| Update will not install over the old app | it was built with a different key (step 6) |
