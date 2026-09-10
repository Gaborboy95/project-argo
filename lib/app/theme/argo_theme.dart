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
    final base = seed == AppSettingKeys.appearanceSeedColor.defaultValue
        ? ThemeData(brightness: brightness, useMaterial3: true)
        : ThemeData(
            brightness: brightness,
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Color(
                0xff000000 | int.parse(seed.substring(1), radix: 16),
              ),
              brightness: brightness,
            ),
          );
    final size = settings.get(AppSettingKeys.appearanceControlSize);
    return base.copyWith(
      textTheme: base.typography.englishLike
          .merge(base.textTheme)
          .apply(fontSizeFactor: size),
      iconTheme: base.iconTheme.copyWith(size: 24 * size),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: Size(48 * size, 48 * size)),
      ),
    );
  }
}
