import 'package:doorbell_call/settings.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const builtIn = Settings(
    serverUrl: 'https://doorbell.example.com',
    cfClientId: 'abc.access',
    cfClientSecret: 'secret',
  );

  test('built-in settings are kept after an update without them', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = SettingsStore();
    expect((await store.load(builtIn)).cfClientId, 'abc.access');
    final updated = await store.load(
      const Settings(serverUrl: '', cfClientId: '', cfClientSecret: ''),
    );
    expect(updated.serverUrl, 'https://doorbell.example.com');
    expect(updated.cfClientSecret, 'secret');
  });

  test('saved settings win over built-in ones', () async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'https://other.example.com',
      'cf_client_id': 'other.access',
      'cf_client_secret': 'other',
    });
    final s = await SettingsStore().load(builtIn);
    expect(s.cfClientId, 'other.access');
  });
}
