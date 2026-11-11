import 'package:flutter/services.dart';

const _channel = MethodChannel('doorbell/lock_screen');

/// Whether the phone is unlocked, asking for its PIN or fingerprint first if
/// the app is showing over the lock screen.
Future<bool> unlockPhone() async {
  try {
    return await _channel.invokeMethod<bool>('unlock') ?? false;
  } on MissingPluginException {
    return true;
  }
}
