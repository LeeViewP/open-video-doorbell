import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'door_page.dart';

class DoorbellApp extends StatelessWidget {
  const DoorbellApp({super.key});

  static const _seed = Color(0xFF4CAF50);

  static ThemeData _theme(ColorScheme? system, Brightness brightness) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: system?.primary ?? _seed,
        brightness: brightness,
      ),
      useMaterial3: true,
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp(
        title: 'Doorbell',
        theme: _theme(light, Brightness.light),
        darkTheme: _theme(dark, Brightness.dark),
        home: const DoorPage(),
      ),
    );
  }
}
