import 'package:flutter/foundation.dart';

/// Set by the call screen's "Answer" button; the door page consumes it (and
/// resets it) to switch the microphone on. A global notifier, not a callback,
/// because the event can arrive before the page exists (cold start).
final ValueNotifier<bool> answerRequested = ValueNotifier<bool>(false);

/// Set by the call screen's "Unlock" button (after the phone's own unlock);
/// the door page consumes it to open the door as soon as its settings are in.
final ValueNotifier<bool> unlockRequested = ValueNotifier<bool>(false);
