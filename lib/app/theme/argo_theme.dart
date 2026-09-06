import 'package:flutter/material.dart';

import '../../core/settings/app_setting_keys.dart';
import '../../core/settings/settings_service.dart';

/// Flutter-only resolution; system brightness is supplied by MaterialApp.
abstract final class ArgoTheme {
  static ThemeMode mode(SettingsService settings) =>
      switch (settings.get(AppSettingKeys.appearanceThemeMode)) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  static ThemeData build(SettingsService settings, Brightness brightness) {
    final seed = settings.get(AppSettingKeys.appearanceSeedColor);
    // Preserve the original Material 3 defaults for the default accent.
    if (seed == AppSettingKeys.appearanceSeedColor.defaultValue) {
      return ThemeData(brightness: brightness, useMaterial3: true);
    }
    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Color(0xff000000 | int.parse(seed.substring(1), radix: 16)),
        brightness: brightness,
      ),
    );
  }
}
