import 'dart:convert';

import 'package:doorbell_call/server_client.dart';
import 'package:doorbell_call/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _settings = Settings(
  serverUrl: 'https://doorbell.example.com/',
  cfClientId: 'abc.access',
  cfClientSecret: 'phone-secret',
);

Matcher _says(String text) => throwsA(
  isA<ServerException>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  test('normalizeBaseUrl strips whitespace and trailing slashes', () {
    expect(
      normalizeBaseUrl(' https://doorbell.example.com// '),
      'https://doorbell.example.com',
    );
  });

  test('open posts to the server with the service token', () async {
    late http.BaseRequest seen;
    final server = DoorbellServer(
      _settings,
      client: MockClient((request) async {
        seen = request;
        return http.Response('{"ok":true}', 200);
      }),
    );

    await server.open();

    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://doorbell.example.com/api/open');
    expect(seen.headers['CF-Access-Client-Id'], 'abc.access');
    expect(seen.headers['CF-Access-Client-Secret'], 'phone-secret');
    expect(seen.followRedirects, isFalse);
  });

  test('answered posts the ring id', () async {
    late http.Request seen;
    final server = DoorbellServer(
      _settings,
      client: MockClient((request) async {
        seen = request;
        return http.Response('{"ok":true}', 200);
      }),
    );

    await server.answered('abc123');

    expect(seen.url.path, '/api/answered');
    expect(jsonDecode(seen.body), {'ring_id': 'abc123'});
    expect(seen.headers['Content-Type'], startsWith('application/json'));
  });

  test('lock state and name from the server', () async {
    final server = DoorbellServer(
      _settings,
      client: MockClient((request) async {
        expect(request.url.path, '/api/state');
        return http.Response(
          jsonEncode({'lock': 'locked', 'name': 'Front gate'}),
          200,
        );
      }),
    );

    final lock = await server.lock();
    expect(lock?.state, 'locked');
    expect(lock?.name, 'Front gate');
  });

  test('history entries', () async {
    final server = DoorbellServer(
      _settings,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'entries': [
              {
                'id': 'a' * 32,
                'kind': 'ring',
                'time': 1000.5,
                'answered_by': null,
                'opened_by': null,
                'picture': true,
              },
              {'id': 'b' * 32, 'kind': 'open', 'time': 900, 'by': 'phone1'},
            ],
          }),
          200,
        ),
      ),
    );

    final [ring, open] = await server.history();
    expect(ring.isRing && ring.missed && ring.hasPicture, isTrue);
    expect(ring.time.millisecondsSinceEpoch, 1000500);
    expect(open.isRing, isFalse);
    expect(open.openedBy, 'phone1');
    expect(
      server.pictureUri(ring.id).toString(),
      'https://doorbell.example.com/api/history/${'a' * 32}/picture',
    );
  });

  test('says why it failed', () async {
    DoorbellServer answering(int code, [String body = '']) => DoorbellServer(
      _settings,
      client: MockClient((_) async => http.Response(body, code)),
    );

    expect(answering(302).readLock(), _says('Cloudflare Access refused'));
    expect(answering(403).open(), _says('Cloudflare Access refused'));
    expect(answering(401).open(), _says('does not know this phone'));
    expect(
      answering(
        502,
        '{"error":"Home Assistant rejected the server\'s token."}',
      ).open(),
      _says('rejected the server'),
    );
    expect(answering(500, 'boom').open(), _says('answered 500'));
    expect(await answering(502).lock(), isNull);
    expect(await answering(502).snapshot(), isNull);
  });

  test('refuses to run when not configured', () {
    expect(DoorbellServer(Settings.empty).open(), _says('Settings'));
  });

  test('signaling goes to the server over wss', () {
    expect(
      DoorbellServer(_settings).signalingUri('talk').toString(),
      'wss://doorbell.example.com/api/ws?kind=talk',
    );
    expect(
      DoorbellServer(
        _settings.copyWith(serverUrl: 'http://doorbell.lan:8099'),
      ).signalingUri('view').toString(),
      'ws://doorbell.lan:8099/api/ws?kind=view',
    );
  });
}
