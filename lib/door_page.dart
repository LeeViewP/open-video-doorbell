import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'answer_signal.dart';
import 'history_page.dart';
import 'hold_button.dart';
import 'live_view.dart';
import 'server_client.dart';
import 'settings.dart';
import 'settings_page.dart';

/// Home screen: live doorbell video, the lock's state, and the actions in
/// one row at the bottom, within reach of the thumb: End (in a call) or Talk
/// (opened by hand), and hold-to-open.
class DoorPage extends StatefulWidget {
  const DoorPage({super.key});

  @override
  State<DoorPage> createState() => _DoorPageState();
}

class _DoorPageState extends State<DoorPage> with WidgetsBindingObserver {
  static const _openedFor = Duration(seconds: 5);

  final _store = SettingsStore();
  Settings _settings = Settings.empty;
  bool _talk = false;
  LockInfo? _lock;
  Uint8List? _still;

  /// The last few rings, shown under the lock's state.
  List<HistoryEntry> _recent = const [];
  bool _busy = false;
  bool _loaded = false;

  /// Opened from the call screen (Answer or Unlock): the microphone is on
  /// and End hangs up; opened by hand, Talk switches the microphone instead.
  bool _inCall = false;

  /// Set when the door was opened, for the confirmation; cleared after
  /// [_openedFor].
  bool _opened = false;
  Timer? _openedTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    answerRequested.addListener(_onAnswer);
    unlockRequested.addListener(_onUnlock);
    _reload();
    _onAnswer();
  }

  /// "Unlock" on the call screen, after the phone's own unlock: open the door
  /// right away. Waits for the settings, so [_reload] calls it again.
  void _onUnlock() {
    if (!unlockRequested.value || !_loaded || _busy) return;
    unlockRequested.value = false;
    setState(() => _inCall = true);
    if (_settings.isConfigured) _open();
  }

  /// "Answer" on the call screen: answering means talking, so the microphone
  /// goes on with the video.
  void _onAnswer() {
    if (!answerRequested.value) return;
    answerRequested.value = false;
    setState(() {
      _talk = true;
      _inCall = true;
    });
  }

  @override
  void dispose() {
    answerRequested.removeListener(_onAnswer);
    unlockRequested.removeListener(_onUnlock);
    WidgetsBinding.instance.removeObserver(this);
    _openedTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Opened from the call screen or brought back from the background.
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    final settings = await _store.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _loaded = true;
    });
    _onUnlock();
    // The still is the same picture the ringing call showed: the server's
    // snapshot, shown while the video connects.
    final server = DoorbellServer(settings);
    final (lock, still, recent) = await (
      server.lock(),
      server.snapshot(),
      _recentRings(server),
    ).wait;
    if (!mounted) return;
    setState(() {
      _lock = lock ?? _lock;
      _still = still ?? _still;
      _recent = recent ?? _recent;
    });
  }

  /// The last three rings, or null if the server could not say.
  static Future<List<HistoryEntry>?> _recentRings(DoorbellServer s) async {
    try {
      return (await s.history()).where((e) => e.isRing).take(3).toList();
    } on ServerException {
      return null;
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
  }

  Future<void> _open() async {
    setState(() => _busy = true);
    String? error;
    try {
      await DoorbellServer(_settings).open();
    } on ServerException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _opened = error == null;
    });
    if (error != null) {
      _say(error);
      return;
    }
    HapticFeedback.heavyImpact();
    _openedTimer?.cancel();
    _openedTimer = Timer(_openedFor, () {
      if (mounted) setState(() => _opened = false);
    });
    // Give the lock a moment to report its new state.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _reload();
  }

  /// Like hanging up a call: the microphone goes off and the app closes,
  /// which also stops the video (see LiveView).
  void _hangUp() {
    setState(() => _talk = false);
    SystemNavigator.pop();
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    await _reload();
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => HistoryPage(settings: _settings)),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, box) {
            // Landscape: video on the left, the rest beside it.
            if (box.maxWidth > box.maxHeight) {
              return Row(
                children: [
                  Expanded(flex: 3, child: Center(child: _video())),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        const Spacer(),
                        _status(),
                        const Spacer(),
                        _panel(),
                      ],
                    ),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _video(),
                _status(),
                Expanded(child: _recentStrip()),
                _panel(),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Edge to edge and 4:3 like the doorbell's picture.
  Widget _video() => AspectRatio(aspectRatio: 4 / 3, child: _preview());

  /// Which lock and in what state, under the video.
  Widget _status() {
    final lock = _lock;
    if (lock == null) return const SizedBox(height: 56);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: _LockStatus(lock),
    );
  }

  /// Who rang lately, at a glance: up to three pictures with the time and
  /// what happened. A tap opens the history.
  Widget _recentStrip() {
    if (!_settings.isConfigured) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Recent',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              TextButton(onPressed: _openHistory, child: const Text('All')),
            ],
          ),
          if (_recent.isEmpty)
            Text(
              _loaded ? 'No rings yet' : '',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: i < _recent.length
                        ? _RecentCard(
                            entry: _recent[i],
                            settings: _settings,
                            onTap: _openHistory,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  /// The actions, in one row at the bottom like a call's.
  Widget _panel() {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelMedium;
    final name = _lock?.name ?? 'the door';
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _opened
                ? _OpenedBanner(key: const ValueKey('opened'), name: name)
                : const SizedBox(key: ValueKey('none'), height: 0),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (_inCall)
                _RoundAction(
                  icon: Icons.call_end,
                  label: 'End',
                  color: Colors.red,
                  onPressed: _hangUp,
                )
              else
                _RoundAction(
                  icon: _talk ? Icons.mic : Icons.mic_none,
                  label: _talk ? 'Talking' : 'Talk',
                  active: _talk,
                  onPressed: _settings.isConfigured
                      ? () => setState(() => _talk = !_talk)
                      : null,
                ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HoldToOpenButton(
                    enabled: _loaded && _settings.isConfigured && !_busy,
                    busy: _busy,
                    onConfirmed: _open,
                  ),
                  const SizedBox(height: 8),
                  Text('Hold to open', style: labelStyle),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    if (_loaded && !_settings.isConfigured) {
      return Center(
        child: FilledButton.tonal(
          onPressed: _openSettings,
          child: const Text('Set up the doorbell'),
        ),
      );
    }
    if (!_loaded) return const SizedBox.shrink();
    return LiveView(
      settings: _settings,
      talk: _talk,
      still: _still,
      onTalkError: (m) {
        if (!mounted) return;
        setState(() => _talk = false);
        _say('Talk failed: $m');
      },
    );
  }
}

/// One recent ring: its picture, the time, and "Missed" or who answered.
class _RecentCard extends StatelessWidget {
  const _RecentCard({
    required this.entry,
    required this.settings,
    required this.onTap,
  });

  final HistoryEntry entry;
  final Settings settings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final who = entry.answeredBy ?? entry.openedBy;
    final (label, color) = entry.missed
        ? ('Missed', scheme.error)
        : (who ?? 'Answered', scheme.onSurfaceVariant);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: entry.hasPicture
                  ? Image.network(
                      DoorbellServer(settings).pictureUri(entry.id).toString(),
                      headers: settings.authHeaders,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          ColoredBox(color: scheme.surfaceContainerHighest),
                    )
                  : ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.doorbell_outlined,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            formatWhen(entry.time, DateTime.now()),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge,
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// "Front gate opened", green, above the buttons for a few seconds.
class _OpenedBanner extends StatelessWidget {
  const _OpenedBanner({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$name opened',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// A round call-screen style button with its label underneath.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;

  /// Fixed background, e.g. red for End; otherwise it follows [active].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filled = active || color != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 64,
          child: IconButton(
            tooltip: label,
            icon: Icon(icon, size: 28),
            style: IconButton.styleFrom(
              backgroundColor:
                  color ??
                  (active ? scheme.primary : scheme.surfaceContainerHighest),
              foregroundColor: color != null
                  ? Colors.white
                  : (filled ? scheme.onPrimary : scheme.onSurface),
            ),
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}

/// The lock's name and state from the server, e.g. "Front gate ·
/// Locked", coloured by state.
class _LockStatus extends StatelessWidget {
  const _LockStatus(this.lock);

  final LockInfo lock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = lock.state;
    final (icon, color) = switch (state) {
      'locked' => (Icons.lock, scheme.onSurfaceVariant),
      'unlocked' || 'open' || 'opening' => (Icons.lock_open, Colors.orange),
      'jammed' => (Icons.warning_amber, scheme.error),
      _ => (Icons.lock_clock, scheme.outline),
    };
    final label = state.isEmpty
        ? 'Unknown'
        : '${state[0].toUpperCase()}${state.substring(1)}';
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${lock.name} · $label',
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
