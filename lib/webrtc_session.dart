import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'go2rtc.dart';

enum SessionKind {
  /// Receives the camera's video and audio.
  view,

  /// Sends the phone's microphone to the camera's speaker (backchannel).
  /// go2rtc only wires the backchannel from a connection's initial offer, so
  /// this is a connection of its own, like Frigate's web player does it.
  talk,
}

/// One WebRTC connection to a go2rtc stream.
class Go2rtcSession {
  Go2rtcSession({
    required this.endpoint,
    required this.kind,
    this.onStream,
    this.onError,
    this.onClosed,
  });

  final Go2rtcEndpoint endpoint;
  final SessionKind kind;
  final void Function(MediaStream stream)? onStream;

  /// Called with a short human-readable reason when the session fails.
  final void Function(String message)? onError;
  final void Function()? onClosed;

  RTCPeerConnection? _pc;
  WebSocket? _ws;
  MediaStream? _mic;
  bool _closed = false;

  /// Local candidates found before the offer went out; go2rtc needs the
  /// offer first, so they wait here.
  List<String>? _earlyCandidates = <String>[];

  /// Incoming messages are handled one after the other: a candidate must not
  /// be added while the answer is still being applied.
  Future<void> _inbox = Future<void>.value();

  Future<void> start() async {
    final ws = await WebSocket.connect(
      endpoint.uri.toString(),
      headers: endpoint.headers,
    ).timeout(endpoint.connectTimeout);
    if (_closed) {
      await ws.close();
      return;
    }
    _ws = ws;

    // go2rtc advertises its own candidates (webrtc.candidates in Frigate's
    // config). STUN lets the phone learn its public address too, for when it
    // is away from home behind the carrier's NAT; Frigate's player does the
    // same. No TURN: media goes straight to go2rtc's port 8555.
    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': <Map<String, dynamic>>[
        <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
      ],
      'bundlePolicy': 'max-bundle',
      'sdpSemantics': 'unified-plan',
    });
    if (_closed) {
      await pc.close();
      await ws.close();
      return;
    }
    _pc = pc;

    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) onStream?.call(event.streams.first);
    };
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      final value = candidate.candidate;
      if (value == null || value.isEmpty || _closed) return;
      final early = _earlyCandidates;
      if (early != null) {
        early.add(value);
      } else {
        ws.add(candidateMessage(value));
      }
    };
    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (_closed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onError?.call('Connection to the camera failed.');
      }
    };

    if (kind == SessionKind.view) {
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    } else {
      final mic = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': true,
        'video': false,
      });
      if (_closed) {
        for (final t in mic.getTracks()) {
          await t.stop();
        }
        await pc.close();
        await ws.close();
        return;
      }
      _mic = mic;
      for (final track in mic.getAudioTracks()) {
        await pc.addTransceiver(
          track: track,
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
        );
      }
    }

    if (_closed) return;
    ws.listen(
      (dynamic data) {
        _inbox = _inbox.then((_) => _onMessage(data)).catchError((Object e) {
          if (!_closed) onError?.call('Signaling failed: $e');
        });
      },
      onDone: () {
        if (!_closed) onClosed?.call();
      },
      onError: (Object e) {
        if (!_closed) onError?.call('Connection lost: $e');
      },
    );

    final offer = await pc.createOffer(<String, dynamic>{});
    await pc.setLocalDescription(offer);
    final sdp = offer.sdp;
    if (sdp == null) {
      throw StateError('WebRTC produced an empty offer');
    }
    ws.add(offerMessage(sdp));
    final early = _earlyCandidates ?? const <String>[];
    _earlyCandidates = null;
    for (final value in early) {
      ws.add(candidateMessage(value));
    }
  }

  Future<void> _onMessage(dynamic data) async {
    if (_closed || data is! String) return;
    final message = parseSignal(data);
    final pc = _pc;
    if (message == null || pc == null) return;
    switch (message.type) {
      case 'webrtc/answer':
        await pc.setRemoteDescription(
          RTCSessionDescription(message.value, 'answer'),
        );
        break;
      case 'webrtc/candidate':
        await pc.addCandidate(RTCIceCandidate(message.value, '0', 0));
        break;
      case 'error':
        // go2rtc answers with an error instead of an answer when it cannot
        // attach the microphone to the camera's backchannel.
        onError?.call(message.value);
        break;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final mic = _mic;
    if (mic != null) {
      for (final t in mic.getTracks()) {
        await t.stop();
      }
      await mic.dispose();
    }
    await _ws?.close();
    await _pc?.close();
    _mic = null;
    _ws = null;
    _pc = null;
  }
}
