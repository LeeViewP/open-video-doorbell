# third_party

## flutter_callkit_incoming 3.1.6 (MIT, see its LICENSE)

Copied from pub.dev (without `example/` and `images/`) and patched for a
third button on the incoming call, **Unlock**, between Decline and Accept.
Every change is marked `doorbell-call patch`:

- `android/.../CallkitUnlock.kt` (new): Unlock is Accept with
  `extra["action"] = "unlock"`; shown only when the call's extra has
  `show_unlock: true`.
- `CallkitIncomingActivity.kt` + `res/layout/activity_callkit_incoming.xml`:
  the button on the full-screen call. On a locked phone it asks for the
  phone's own unlock (PIN, fingerprint) before going on. Answer no longer
  dismisses the lock screen: the app shows over it during the call.
- `CallkitNotificationManager.kt`: the same action in the call notification
  (Android 14+ call style), with `setAuthenticationRequired(true)`.
- `SharedPreferencesUtils.kt`: an accepted call keeps the extra it was
  accepted with, so `activeCalls()` tells Unlock from Answer after a cold
  start.
- `res/drawable/ic_unlock.xml`, `bg_button_unlock.xml`, string `text_unlock`.
- `CallkitLivePreview.kt` (new) + `svPreview` in the layout: live video on
  the ringing screen, from the call's `extra["preview_url"]` (the doorbell
  server's go2rtc signaling relay) with the call's headers. Video only, so
  the ringtone is the only sound; the background picture is hidden once the
  first frame is on screen, and the connection closes with the activity.
  WebRTC is `compileOnly` here: the app ships it through flutter_webrtc.
- `CallkitConnectionService.kt`: an incoming call whose handle is not a
  phone number gets a `sip:<caller name>` address instead of `tel:<handle>`
  (a paired Galaxy Watch showed "15" for "push 1.5 s").
- `CallkitIncomingActivity.getIntentEnded`: the "call ended" broadcast no
  longer names the activity class as its component, so the open call screen
  closes when the call is ended from code (upstream bug: it stayed until the
  timeout).
- The three call buttons are 120dp wide instead of 150dp, so they fit a
  ~410dp phone screen.
- `widgets/RippleRelativeLayout.kt` (`hideRipples`): with a background
  picture (the doorbell snapshot) the rings around the caller are hidden, so
  they do not cover the visitor's face.

Android below 14 shows the button on the full-screen call only, not in the
notification. iOS is untouched.

To move to a newer upstream version, copy it over and redo the marked
changes.
