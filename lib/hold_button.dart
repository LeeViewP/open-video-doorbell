import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The lock must be held for one second so it cannot open from a stray tap or
/// a pocket press. A white arc runs round the button's edge to show the
/// progress; letting go resets it. Same size and shape as the page's other
/// round buttons.
class HoldToOpenButton extends StatefulWidget {
  const HoldToOpenButton({
    super.key,
    required this.enabled,
    required this.busy,
    required this.onConfirmed,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onConfirmed;

  @override
  State<HoldToOpenButton> createState() => _HoldToOpenButtonState();
}

class _HoldToOpenButtonState extends State<HoldToOpenButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            HapticFeedback.heavyImpact();
            widget.onConfirmed();
            _hold.value = 0;
          }
        });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Hold to open the door',
      child: GestureDetector(
        onTapDown: enabled ? (_) => _hold.forward() : null,
        onTapUp: (_) => _hold.reverse(),
        onTapCancel: () => _hold.reverse(),
        child: SizedBox.square(
          dimension: 64,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: enabled
                      ? Colors.green
                      : scheme.surfaceContainerHighest,
                ),
                child: Center(
                  child: widget.busy
                      ? const SizedBox.square(
                          dimension: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          Icons.lock_open,
                          size: 28,
                          color: enabled
                              ? Colors.white
                              : scheme.onSurface.withValues(alpha: 0.38),
                        ),
                ),
              ),
              AnimatedBuilder(
                animation: _hold,
                builder: (_, _) => _hold.value == 0
                    ? const SizedBox.shrink()
                    : CircularProgressIndicator(
                        value: _hold.value,
                        strokeWidth: 4,
                        color: Colors.white,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
