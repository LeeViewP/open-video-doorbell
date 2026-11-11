import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the doorbell server is and this phone's key to it, kept in the
/// Android keystore-backed secure storage. Everything else (Home Assistant,
/// the lock, the camera stream) is configured on the server.
class Settings {
  const Settings({
    required this.serverUrl,
    required this.cfClientId,
    required this.cfClientSecret,
  });

  /// The doorbell server, e.g. `https://doorbell.example.com`.
  final String serverUrl;

  /// This phone's Cloudflare Access service token. It gets requests through
  /// Access, and the server checks it against its list of phones.
  final String cfClientId;
  final String cfClientSecret;

  bool get isConfigured =>
      serverUrl.isNotEmpty &&
      cfClientId.isNotEmpty &&
      cfClientSecret.isNotEmpty;

  /// Headers for every request to the server.
  Map<String, String> get authHeaders => {
    'CF-Access-Client-Id': cfClientId.trim(),
    'CF-Access-Client-Secret': cfClientSecret.trim(),
  };

  static const empty = Settings(
    serverUrl: '',
    cfClientId: '',
    cfClientSecret: '',
  );

  Settings copyWith({
    String? serverUrl,
    String? cfClientId,
    String? cfClientSecret,
  }) {
    return Settings(
      serverUrl: serverUrl ?? this.serverUrl,
      cfClientId: cfClientId ?? this.cfClientId,
      cfClientSecret: cfClientSecret ?? this.cfClientSecret,
    );
  }
}

/// Removes whitespace and any trailing slashes from a user-typed base URL.
String normalizeBaseUrl(String raw) {
  var url = raw.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

class SettingsStore {
  SettingsStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kServer = 'server_url';
  static const _kCfId = 'cf_client_id';
  static const _kCfSecret = 'cf_client_secret';

  /// Left by versions that talked to Home Assistant and go2rtc directly;
  /// removed on save so the Home Assistant token is no longer on the phone.
  static const _legacy = [
    'ha_url',
    'ha_token',
    'lock_entity',
    'camera_entity',
    'lock_service',
    'go2rtc_url',
    'stream_name',
    'external_go2rtc_url',
  ];

  /// Settings baked into a build for one phone, so it works on first start:
  /// `flutter build apk --dart-define-from-file=phone.json` with the keys
  /// below. Saved on the phone then, so updates built without them keep it.
  static const builtIn = Settings(
    serverUrl: String.fromEnvironment('DOORBELL_SERVER_URL'),
    cfClientId: String.fromEnvironment('DOORBELL_CF_CLIENT_ID'),
    cfClientSecret: String.fromEnvironment('DOORBELL_CF_CLIENT_SECRET'),
  );

  Future<Settings> load([Settings firstStart = builtIn]) async {
    final serverUrl = await _storage.read(key: _kServer);
    if (serverUrl == null) {
      if (firstStart.isConfigured) await save(firstStart);
      return firstStart;
    }
    return Settings(
      serverUrl: serverUrl,
      cfClientId: await _storage.read(key: _kCfId) ?? '',
      cfClientSecret: await _storage.read(key: _kCfSecret) ?? '',
    );
  }

  Future<void> save(Settings s) async {
    await _storage.write(key: _kServer, value: normalizeBaseUrl(s.serverUrl));
    await _storage.write(key: _kCfId, value: s.cfClientId.trim());
    await _storage.write(key: _kCfSecret, value: s.cfClientSecret.trim());
    for (final key in _legacy) {
      await _storage.delete(key: key);
    }
  }
}
