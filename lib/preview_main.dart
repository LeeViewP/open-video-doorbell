import 'package:flutter/material.dart';

import 'app.dart';

/// UI preview without Firebase or the call screen, for running in a browser:
/// `flutter run -d edge -t lib/preview_main.dart`. The real entry point is
/// `main.dart`, which needs `google-services.json` and Android.
void main() {
  runApp(const DoorbellApp());
}
