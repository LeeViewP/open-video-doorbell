import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'answer_signal.dart';
import 'app.dart';
import 'call_service.dart';
import 'push.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Listen before anything else can wait: "Answer" or "Unlock" has already
  // brought this activity to the front, so end the call UI and ask the door
  // page to start talking or to open the door. "Dismiss" only ends the call.
  FlutterCallkitIncoming.onEvent.listen((CallEvent? event) async {
    switch (event) {
      case CallEventActionCallAccept(:final callKitParams):
        _act(callChoice(callKitParams.extra));
        unawaited(reportAnswered(callKitParams.extra));
        await FlutterCallkitIncoming.endAllCalls();
      case CallEventActionCallDecline():
      case CallEventActionCallTimeout():
        await FlutterCallkitIncoming.endAllCalls();
      default:
        break;
    }
  });

  // Show the door page right away; nothing below may hold it back, since the
  // app is often opened from "Answer" with someone waiting at the door.
  runApp(const DoorbellApp());
  await _startup();
}

void _act(CallChoice choice) {
  switch (choice) {
    case CallChoice.answer:
      answerRequested.value = true;
    case CallChoice.unlock:
      unlockRequested.value = true;
  }
}

Future<void> _startup() async {
  try {
    final call = await callAnsweredBeforeStart();
    if (call != null) {
      _act(callChoice(call.extra));
      unawaited(reportAnswered(call.extra));
      await FlutterCallkitIncoming.endAllCalls();
    }
  } catch (e) {
    debugPrint('Could not read the active calls: $e');
  }
  // Network-dependent (topic subscription) and may show dialogs; a failure
  // here must not keep the app from opening the door.
  try {
    await initPush();
  } catch (e) {
    debugPrint('Push setup failed: $e');
  }
  try {
    await requestCallPermissions();
  } catch (e) {
    debugPrint('Call permission request failed: $e');
  }
}
