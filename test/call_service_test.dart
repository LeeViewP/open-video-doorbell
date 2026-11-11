import 'package:doorbell_call/call_service.dart';
import 'package:doorbell_call/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('push delay from the sender timestamp', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000);
    expect(pushDelayText('999200', now), 'push 0.8 s');
    expect(pushDelayText('988000', now), 'push 12.0 s');
    // Phone clock slightly behind the sender's.
    expect(pushDelayText('1000300', now), 'push 0.0 s');
    expect(pushDelayText(null, now), isNull);
    expect(pushDelayText('soon', now), isNull);
  });

  test('Unlock is told apart from Answer by the extra', () {
    expect(
      callChoice({'source': 'doorbell', 'action': 'unlock'}),
      CallChoice.unlock,
    );
    expect(callChoice({'source': 'doorbell'}), CallChoice.answer);
    expect(callChoice(null), CallChoice.answer);
  });

  group('ringPicture', () {
    final now = DateTime.fromMillisecondsSinceEpoch(42);

    test('the server snapshot, with the service token', () {
      final p = ringPicture(
        const Settings(
          serverUrl: 'https://doorbell.example.com/',
          cfClientId: 'abc.access',
          cfClientSecret: 'phone-secret',
        ),
        now,
      );
      expect(p?.url, 'https://doorbell.example.com/api/snapshot?ring=42');
      expect(p?.headers, {
        'CF-Access-Client-Id': 'abc.access',
        'CF-Access-Client-Secret': 'phone-secret',
      });
    });

    test('nothing to show before the server is set', () {
      expect(ringPicture(Settings.empty, now), isNull);
    });
  });
}
