import 'package:doorbell_call/go2rtc.dart';
import 'package:doorbell_call/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signaling endpoint: the server, with the service token', () {
    final e = signalingEndpoint(
      const Settings(
        serverUrl: 'https://doorbell.example.com',
        cfClientId: 'abc.access',
        cfClientSecret: 'phone-secret',
      ),
      'view',
    );
    expect(e?.uri.toString(), 'wss://doorbell.example.com/api/ws?kind=view');
    expect(e?.headers, {
      'CF-Access-Client-Id': 'abc.access',
      'CF-Access-Client-Secret': 'phone-secret',
    });
    expect(signalingEndpoint(Settings.empty, 'view'), isNull);
  });

  test('parses signaling messages', () {
    final m = parseSignal('{"type":"webrtc/answer","value":"v=0"}');
    expect(m?.type, 'webrtc/answer');
    expect(m?.value, 'v=0');
    expect(parseSignal('nope'), isNull);
    expect(parseSignal('[1]'), isNull);
    expect(parseSignal('{"value":"x"}'), isNull);
    expect(parseSignal('{"type":"error"}')?.value, '');
  });

  test('encodes offer and candidate', () {
    expect(offerMessage('sdp'), '{"type":"webrtc/offer","value":"sdp"}');
    expect(candidateMessage('c'), '{"type":"webrtc/candidate","value":"c"}');
  });
}
