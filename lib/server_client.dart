import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'settings.dart';

/// The lock as the server reports it, e.g. ("locked", "Front gate").
typedef LockInfo = ({String state, String name});

/// One line of the server's history: a ring (with who answered and who
/// opened) or an opening with no ring before it.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.isRing,
    required this.time,
    this.answeredBy,
    this.openedBy,
    this.hasPicture = false,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> j) {
    final isRing = j['kind'] == 'ring';
    return HistoryEntry(
      id: j['id'] as String,
      isRing: isRing,
      time: DateTime.fromMillisecondsSinceEpoch(
        ((j['time'] as num) * 1000).round(),
      ),
      answeredBy: j['answered_by'] as String?,
      // An opening on its own names who opened as "by".
      openedBy: (isRing ? j['opened_by'] : j['by']) as String?,
      hasPicture: j['picture'] == true,
    );
  }

  final String id;
  final bool isRing;
  final DateTime time;
  final String? answeredBy;
  final String? openedBy;
  final bool hasPicture;

  /// Rang and nobody answered or opened.
  bool get missed => isRing && answeredBy == null && openedBy == null;
}

class ServerException implements Exception {
  ServerException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The doorbell server (`server/` in this repo): lock state, opening the
/// door and a snapshot. The video's signaling is in [signalingUri].
class DoorbellServer {
  DoorbellServer(this.settings, {http.Client? client})
    : _http = client ?? http.Client();

  final Settings settings;
  final http.Client _http;

  static const _timeout = Duration(seconds: 10);

  Uri uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(normalizeBaseUrl(settings.serverUrl));
    return base.replace(path: '${base.path}$path', queryParameters: query);
  }

  /// go2rtc's WebRTC signaling, relayed by the server. [kind] (`view` or
  /// `talk`) only labels the connection in the server's log.
  Uri signalingUri(String kind) {
    final u = uri('/api/ws', {'kind': kind});
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws');
  }

  /// Sends one request; throws [ServerException] saying what went wrong.
  Future<http.Response> _send(
    String method,
    String path, [
    Map<String, Object?>? json,
  ]) async {
    if (!settings.isConfigured) {
      throw ServerException('Set the server and its key in Settings.');
    }
    final request = http.Request(method, uri(path))
      // Cloudflare Access answers a refused token with a redirect to its
      // login page; followed, that would look like a 200.
      ..followRedirects = false
      ..headers.addAll(settings.authHeaders);
    if (json != null) {
      request
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(json);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _http.send(request).timeout(_timeout),
      ).timeout(_timeout);
    } catch (e) {
      throw ServerException('Could not reach the doorbell server: $e');
    }
    final code = res.statusCode;
    if ((code >= 300 && code < 400) || code == 403) {
      throw ServerException(
        'Cloudflare Access refused this phone (check the Client ID and '
        'secret).',
      );
    }
    if (code == 401) {
      throw ServerException(
        'The doorbell server does not know this phone (its Client ID is not '
        'in the server\'s list).',
      );
    }
    if (code != 200) {
      throw ServerException(_errorText(res) ?? 'The server answered $code.');
    }
    return res;
  }

  static String? _errorText(http.Response res) {
    try {
      final error = (jsonDecode(res.body) as Map<String, dynamic>)['error'];
      return error is String ? error : null;
    } catch (_) {
      return null;
    }
  }

  /// The lock's state (`locked`, `unlocked`, `open`, ...) and its name in
  /// Home Assistant; says why it failed: used by "Test connection".
  Future<LockInfo> readLock() async {
    final res = await _send('GET', '/api/state');
    final Object? state, name;
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      state = body['lock'];
      name = body['name'];
    } catch (_) {
      throw ServerException('Unexpected answer from the doorbell server.');
    }
    if (state is! String) {
      throw ServerException('Unexpected answer from the doorbell server.');
    }
    return (state: state, name: name is String ? name : 'Door');
  }

  /// Like [readLock], or null if it failed.
  Future<LockInfo?> lock() async {
    try {
      return await readLock();
    } on ServerException {
      return null;
    }
  }

  /// The last rings and door openings, newest first.
  Future<List<HistoryEntry>> history() async {
    final res = await _send('GET', '/api/history');
    try {
      final entries = (jsonDecode(res.body) as Map<String, dynamic>)['entries'];
      return [
        for (final e in entries as List)
          HistoryEntry.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      throw ServerException('Unexpected answer from the doorbell server.');
    }
  }

  /// The picture taken when ring [id] rang; load it with
  /// [Settings.authHeaders].
  Uri pictureUri(String id) => uri('/api/history/$id/picture');

  /// Opens the door (the server calls the lock in Home Assistant).
  Future<void> open() async {
    await _send('POST', '/api/open');
  }

  /// This phone answered ring [ringId]: the server stops it on the others.
  Future<void> answered(String ringId) async {
    await _send('POST', '/api/answered', {'ring_id': ringId});
  }

  /// The version code of the app the server offers, or null if none.
  Future<int?> latestAppVersion() async {
    try {
      final res = await _send('GET', '/api/app');
      final version = (jsonDecode(res.body) as Map<String, dynamic>)['version'];
      return version is int ? version : null;
    } catch (_) {
      return null;
    }
  }

  /// Saves the app the server offers to [file].
  Future<void> downloadApp(
    File file,
    void Function(double done) onProgress,
  ) async {
    final request = http.Request('GET', uri('/api/app/apk'))
      ..followRedirects = false
      ..headers.addAll(settings.authHeaders);
    final res = await _http.send(request);
    if (res.statusCode != 200) {
      throw ServerException('The server answered ${res.statusCode}.');
    }
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
    } finally {
      await sink.close();
    }
  }

  /// The doorbell's current picture, or null if it could not be fetched.
  Future<Uint8List?> snapshot() async {
    try {
      return (await _send('GET', '/api/snapshot')).bodyBytes;
    } on ServerException {
      return null;
    }
  }
}
