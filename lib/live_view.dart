import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'go2rtc.dart';
import 'settings.dart';
import 'webrtc_session.dart';

/// Live doorbell video from go2rtc. With [talk] on, the phone's microphone is
/// also sent to the doorbell's speaker over a second connection.
class LiveView extends StatefulWidget {
  const LiveView({
    super.key,
    required this.settings,
    required this.talk,
    this.still,
    this.onTalkError,
  });

  final Settings settings;
  final bool talk;

  /// Camera snapshot from Home Assistant, shown while the live video is not
  /// playing (loading, or away from home where go2rtc is out of reach).
  final Uint8List? still;

  /// Called when talking failed (no mic permission, or the camera has no
  /// backchannel), so the page can switch its talk button back off.
  final void Function(String message)? onTalkError;

  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> with WidgetsBindingObserver {
  static const _retryDelay = Duration(seconds: 5);

  final _renderer = RTCVideoRenderer();
  Go2rtcSession? _view;
  Go2rtcSession? _talk;
  Timer? _retry;
  String? _error;
  bool _rendererReady = false;
  bool _playing = false;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _renderer.initialize();
    if (!mounted) return;
    // Playing once a frame is on screen, not when the track arrives: the
    // track comes with the answer, frames only after the first keyframe, and
    // until then the still picture stays up instead of a black box.
    _renderer.onFirstFrameRendered = () {
      if (mounted && _view != null) setState(() => _playing = true);
    };
    _rendererReady = true;
    await _startView();
    if (widget.talk) await _startTalk();
  }

  @override
  void didUpdateWidget(LiveView old) {
    super.didUpdateWidget(old);
    final o = old.settings, s = widget.settings;
    final changed =
        o.serverUrl != s.serverUrl ||
        o.cfClientId != s.cfClientId ||
        o.cfClientSecret != s.cfClientSecret;
    if (changed) {
      _restart();
    } else if (old.talk != widget.talk) {
      widget.talk ? _startTalk() : _stopTalk();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Do not hold the camera connection or the microphone in the background.
    if (state == AppLifecycleState.paused) {
      _paused = true;
      _stopAll();
    } else if (state == AppLifecycleState.resumed) {
      _paused = false;
      if (_view == null) _restart();
    }
  }

  Future<void> _restart() async {
    await _stopAll();
    if (!mounted || !_rendererReady || _paused) return;
    await _startView();
    if (widget.talk) await _startTalk();
  }

  /// The video dropped or never came up: close what is left and try again a
  /// little later (go2rtc restarting, Wi-Fi coming back).
  void _failView(Go2rtcSession session, String message) {
    if (!identical(_view, session)) return;
    _view = null;
    session.close();
    _retryLater(message);
  }

  void _retryLater(String message) {
    if (!mounted) return;
    setState(() {
      _playing = false;
      _error = '$message\nRetrying...';
    });
    _retry?.cancel();
    _retry = Timer(_retryDelay, () {
      if (mounted && !_paused && _view == null) _restart();
    });
  }

  Future<void> _startView() async {
    _retry?.cancel();
    final endpoint = signalingEndpoint(widget.settings, 'view');
    if (endpoint == null) {
      setState(() => _error = 'Set the doorbell server in Settings.');
      return;
    }
    setState(() {
      _error = null;
      _playing = false;
    });
    late final Go2rtcSession session;
    session = Go2rtcSession(
      endpoint: endpoint,
      kind: SessionKind.view,
      onStream: (stream) {
        if (!mounted || !identical(_view, session)) return;
        _renderer.srcObject = stream;
      },
      onError: (m) => _failView(session, m),
      onClosed: () => _failView(session, 'The stream closed.'),
    );
    _view = session;
    try {
      await session.start();
    } catch (e) {
      // Stopped or restarted meanwhile: that call takes it from here.
      if (!identical(_view, session)) return;
      _view = null;
      await session.close();
      _retryLater('Could not open the stream: $e');
    }
  }

  Future<void> _startTalk() async {
    final endpoint = signalingEndpoint(widget.settings, 'talk');
    if (endpoint == null || _talk != null || _paused) return;
    late final Go2rtcSession session;
    void fail(String message) {
      if (!identical(_talk, session)) return;
      _stopTalk();
      widget.onTalkError?.call(message);
    }

    session = Go2rtcSession(
      endpoint: endpoint,
      kind: SessionKind.talk,
      onError: fail,
      onClosed: () => fail('The talk connection closed.'),
    );
    _talk = session;
    try {
      await session.start();
    } catch (e) {
      fail('Could not start the microphone: $e');
    }
  }

  Future<void> _stopTalk() async {
    final s = _talk;
    _talk = null;
    await s?.close();
  }

  Future<void> _stopAll() async {
    _retry?.cancel();
    await _stopTalk();
    final v = _view;
    _view = null;
    await v?.close();
    if (mounted) setState(() => _playing = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _talk?.close();
    _view?.close();
    _renderer.srcObject = null;
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = widget.still;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_rendererReady)
            RTCVideoView(
              _renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
          // Above the video view: after a drop it still holds the last frame.
          if (!_playing && still != null)
            Image.memory(still, fit: BoxFit.contain, gaplessPlayback: true),
          if (!_playing && _error == null)
            const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Center(
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
          if (_playing)
            Positioned(
              top: 8,
              left: 8,
              child: _LiveBadge(talking: widget.talk && _talk != null),
            ),
        ],
      ),
    );
  }
}

/// "● LIVE" over the video, with a mic while the doorbell hears you.
class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.talking});

  final bool talking;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, size: 10, color: Colors.redAccent),
          const SizedBox(width: 6),
          const Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
          if (talking) ...[
            const SizedBox(width: 8),
            const Icon(Icons.mic, size: 16, color: Colors.redAccent),
          ],
        ],
      ),
    );
  }
}
