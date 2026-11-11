import 'dart:io';

import 'package:flutter/services.dart';

import 'server_client.dart';

const _channel = MethodChannel('doorbell/update');

/// The server's app version if it is newer than this one, else null.
Future<int?> availableUpdate(DoorbellServer server) async {
  final latest = await server.latestAppVersion();
  if (latest == null) return null;
  try {
    final installed = await _channel.invokeMethod<int>('versionCode');
    return installed != null && latest > installed ? latest : null;
  } on MissingPluginException {
    return null;
  }
}

/// This app's version for people, e.g. "2026.11.11-1924 (263151924)".
Future<String?> appVersion() async {
  try {
    final name = await _channel.invokeMethod<String>('versionName');
    final code = await _channel.invokeMethod<int>('versionCode');
    return '$name ($code)';
  } on MissingPluginException {
    return null;
  }
}

/// Downloads the server's app and hands it to Android's installer.
Future<void> installUpdate(
  DoorbellServer server,
  void Function(double done) onProgress,
) async {
  final path = await _channel.invokeMethod<String>('apkPath');
  await server.downloadApp(File(path!), onProgress);
  await _channel.invokeMethod<void>('install', path);
}
