import 'package:firebase_app_installations/firebase_app_installations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'call_service.dart';
import 'server_client.dart';
import 'settings.dart';

/// The topic older versions listened on; left once the server has this
/// phone's own token, so no ring goes missing in between.
const _oldTopic = 'doorbell';

/// Runs in a background isolate when a data message arrives and the app is not
/// in the foreground (including after the process was killed).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await _handle(message.data);
}

/// A ring shows the call; "answered" (someone else took it) stops it here.
Future<void> _handle(Map<String, dynamic> data) async {
  switch (data['type']) {
    case 'doorbell':
      await showDoorbellCall(data);
    case 'doorbell_answered':
      await stopRingingFor(data);
  }
}

/// This phone's Firebase Installation ID once Firebase has given it.
String? _fid;

Future<void> initPush() async {
  // First, so a ring in the foreground is shown even if the steps below fail.
  FirebaseMessaging.onMessage.listen((message) => _handle(message.data));
  FirebaseMessaging.instance.onRegistered.listen((fid) {
    _fid = fid;
    _tellServer(fid);
  });
  await FirebaseMessaging.instance.requestPermission();
  await FirebaseMessaging.instance.register();
  final fid = await FirebaseInstallations.instance.getId();
  _fid ??= fid;
  await registerForPush();
}

/// Tells the server where this phone's pushes go. Every start does it again,
/// so a missed one (offline, settings changed) is made up for.
Future<void> registerForPush() async {
  final fid = _fid;
  if (fid != null) await _tellServer(fid);
}

Future<void> _tellServer(String fid) async {
  final settings = await SettingsStore().load();
  if (!settings.isConfigured) return;
  try {
    await DoorbellServer(settings).registerForPush(fid);
  } on ServerException {
    return;
  }
  await FirebaseMessaging.instance.unsubscribeFromTopic(_oldTopic);
}
