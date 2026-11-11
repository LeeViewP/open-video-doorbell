import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:uuid/uuid.dart';

import 'server_client.dart';
import 'settings.dart';

/// Shows the Android full-screen "incoming call" UI for a doorbell press.
///
/// `data` is the FCM data payload sent by the server (see `server/`); every
/// key is optional so a bare `{}` still rings.
Future<void> showDoorbellCall(Map<String, dynamic> data) async {
  final title = (data['title'] as String?) ?? 'Doorbell';
  var body = (data['body'] as String?) ?? 'Someone is at the door';
  final delay = pushDelayText(data['sent_at'] as String?, DateTime.now());
  if (delay != null) body = '$body · $delay';

  // Only one doorbell call at a time: a second press replaces the first.
  await FlutterCallkitIncoming.endAllCalls();

  // The settings only add the picture; the call rings without them.
  Settings? settings;
  try {
    settings = await SettingsStore().load();
  } catch (_) {}
  final picture = settings == null
      ? null
      : ringPicture(settings, DateTime.now());

  final params = CallKitParams(
    id: const Uuid().v4(),
    nameCaller: title,
    appName: 'Doorbell',
    handle: body,
    // Video: the notification says "video call" and shows a camera icon.
    type: 1,
    duration: 30000,
    headers: picture?.headers,
    missedCallNotification: const NotificationParams(
      showNotification: true,
      isShowCallback: false,
      subtitle: 'Missed doorbell',
    ),
    // For the patched plugin (third_party/README.md): show_unlock adds the
    // Unlock button, preview_url the live video behind the call screen
    // (same headers as the picture).
    extra: <String, dynamic>{
      'source': 'doorbell',
      // Answering reports it, so the other phones stop ringing.
      'ring_id': data['ring_id'] ?? '',
      'show_unlock': true,
      if (settings != null && settings.isConfigured)
        'preview_url': DoorbellServer(
          settings,
        ).signalingUri('preview').toString(),
    },
    android: AndroidParams(
      isCustomNotification: true,
      isShowLogo: false,
      ringtonePath: 'system_ringtone_default',
      backgroundColor: '#1b1f27',
      backgroundUrl: picture?.url,
      actionColor: '#4CAF50',
      textColor: '#ffffff',
      incomingCallNotificationChannelName: 'Doorbell',
      missedCallNotificationChannelName: 'Missed doorbell',
      isShowFullLockedScreen: true,
      // The "handle" line: "Someone is at the door · push 0.8 s".
      isShowCallID: true,
      textAccept: 'Answer',
      textDecline: 'Dismiss',
    ),
  );
  await FlutterCallkitIncoming.showCallkitIncoming(params);
}

/// The picture behind the ringing call screen: who is at the door right now,
/// the server's snapshot. [now] keeps the image loader from showing the
/// picture it cached at the last ring.
({String url, Map<String, String> headers})? ringPicture(
  Settings s,
  DateTime now,
) {
  if (!s.isConfigured) return null;
  final uri = DoorbellServer(
    s,
  ).uri('/api/snapshot', {'ring': '${now.millisecondsSinceEpoch}'});
  return (url: uri.toString(), headers: s.authHeaders);
}

/// How long the push took from the server to this phone, e.g. "push 0.8 s",
/// from the server's `sent_at` (Unix ms). Null if missing or unreadable.
/// Both clocks are NTP-synced, so it is good to a few tenths of a second.
String? pushDelayText(String? sentAt, DateTime now) {
  final sent = int.tryParse(sentAt ?? '');
  if (sent == null) return null;
  final ms = now.millisecondsSinceEpoch - sent;
  if (ms < 0) return 'push 0.0 s';
  return 'push ${(ms / 1000).toStringAsFixed(1)} s';
}

/// What the call screen's buttons ask the app to do once it is up.
enum CallChoice { answer, unlock }

/// Answer or Unlock, from an accepted call's extra (Unlock adds
/// `action: unlock`; see third_party/README.md).
CallChoice callChoice(Map<String, dynamic>? extra) =>
    extra?['action'] == 'unlock' ? CallChoice.unlock : CallChoice.answer;

/// The doorbell call answered before this isolate could listen for the event,
/// or null: "Answer" with the app killed starts it fresh, and the accept
/// event fires before `main()` subscribes. The plugin still lists the call as
/// accepted, so it is read back from there.
Future<CallKitParams?> callAnsweredBeforeStart() async {
  final calls = await FlutterCallkitIncoming.activeCalls();
  for (final call in calls) {
    if (call.isAccepted) return call;
  }
  return null;
}

/// This phone answered (or unlocked from) a call: the server tells the other
/// phones to stop ringing. Best effort; the call goes on either way.
Future<void> reportAnswered(Map<String, dynamic>? extra) async {
  final ringId = extra?['ring_id'];
  if (ringId is! String || ringId.isEmpty) return;
  try {
    await DoorbellServer(await SettingsStore().load()).answered(ringId);
  } catch (_) {}
}

/// Someone else answered ring `data['ring_id']`: stop it ringing here and
/// say who took it, so the call does not just vanish. A call this phone
/// already answered is left alone.
Future<void> stopRingingFor(Map<String, dynamic> data) async {
  final ringId = data['ring_id'];
  if (ringId is! String || ringId.isEmpty) return;
  final by = data['by'] as String?;
  for (final call in await FlutterCallkitIncoming.activeCalls()) {
    if (call.isAccepted || call.extra?['ring_id'] != ringId) continue;
    await FlutterCallkitIncoming.endCall(call.id);
    await FlutterCallkitIncoming.showMissCallNotification(
      CallKitParams(
        id: call.id,
        nameCaller: call.nameCaller ?? 'Doorbell',
        appName: 'Doorbell',
        handle: call.handle,
        type: call.type,
        missedCallNotification: NotificationParams(
          showNotification: true,
          isShowCallback: false,
          subtitle: by == null || by.isEmpty ? 'Answered' : 'Answered by $by',
        ),
        android: const AndroidParams(
          missedCallNotificationChannelName: 'Missed doorbell',
        ),
      ),
    );
  }
}

/// Android 13+ notification permission and Android 14+ full-screen-intent
/// permission; without the second one the call only shows as a heads-up
/// notification on the lock screen.
Future<void> requestCallPermissions() async {
  await FlutterCallkitIncoming.requestNotificationPermission(<String, dynamic>{
    'title': 'Notification permission',
    'rationaleMessagePermission':
        'Notifications are needed to ring when the doorbell is pressed.',
    'postNotificationMessageRequired':
        'Allow notifications in Settings so the doorbell can ring.',
  });
  final canFullScreen = await FlutterCallkitIncoming.canUseFullScreenIntent();
  if (canFullScreen != true) {
    await FlutterCallkitIncoming.requestFullIntentPermission();
  }
}
