import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'call_service.dart';

/// Topic both phones subscribe to; the server publishes to it, so the app
/// never has to hand device tokens to anything.
const doorbellTopic = 'doorbell';

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

/// Throws if the topic subscription fails (offline); every app start
/// subscribes again.
Future<void> initPush() async {
  // First, so a ring in the foreground is shown even if the steps below fail.
  FirebaseMessaging.onMessage.listen((message) => _handle(message.data));

  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission();
  await messaging.subscribeToTopic(doorbellTopic);
}
