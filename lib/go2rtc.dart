import 'dart:convert';

import 'server_client.dart';
import 'settings.dart';

/// go2rtc WebSocket signaling, the same protocol Frigate's own web player
/// speaks (`web/src/components/player/WebRTCPlayer.tsx`): JSON messages
/// `webrtc/offer`, `webrtc/answer`, `webrtc/candidate` and `error`. The
/// doorbell server relays it to go2rtc for the doorbell's stream.

/// Where to open the signaling WebSocket, and with which headers.
class Go2rtcEndpoint {
  const Go2rtcEndpoint(
    this.uri, {
    this.headers = const {},
    required this.connectTimeout,
  });

  final Uri uri;
  final Map<String, String> headers;
  final Duration connectTimeout;
}

/// The server's signaling relay; [kind] is `view` or `talk`. Null until the
/// server is set up.
Go2rtcEndpoint? signalingEndpoint(Settings s, String kind) {
  if (!s.isConfigured) return null;
  return Go2rtcEndpoint(
    DoorbellServer(s).signalingUri(kind),
    headers: s.authHeaders,
    connectTimeout: const Duration(seconds: 10),
  );
}

class SignalMessage {
  const SignalMessage(this.type, this.value);

  final String type;
  final String value;
}

/// Parses one WebSocket text frame; returns null if it is not a signaling
/// message.
SignalMessage? parseSignal(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final type = decoded['type'];
    if (type is! String) return null;
    return SignalMessage(type, (decoded['value'] ?? '').toString());
  } catch (_) {
    return null;
  }
}

String offerMessage(String sdp) =>
    jsonEncode({'type': 'webrtc/offer', 'value': sdp});

String candidateMessage(String candidate) =>
    jsonEncode({'type': 'webrtc/candidate', 'value': candidate});
