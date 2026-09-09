import 'package:flutter/material.dart';

import '../../core/settings/app_setting_keys.dart';
import '../../core/settings/settings_service.dart';

class AppearanceSettingsCard extends StatelessWidget {
  const AppearanceSettingsCard({required this.settings, super.key});

  final SettingsService settings;

  static const _accents = {
    '#6750A4': 'Purple (default)',
    '#006A6A': 'Teal',
    '#005AC1': 'Blue',
    '#895100': 'Amber',
  };

  Future<void> _save(
    BuildContext context,
    Future<void> Function() write,
  ) async {
    try {
      await write();
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save appearance settings.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<SettingChange>(
    stream: settings.changes,
    builder: (context, _) {
      final mode = settings.get(AppSettingKeys.appearanceThemeMode);
      final accent = settings.get(AppSettingKeys.appearanceSeedColor);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(('theme-mode', mode)),
                initialValue: mode,
                decoration: const InputDecoration(labelText: 'Theme mode'),
                items: [
                  for (final value in ['light', 'dark', 'system'])
                    DropdownMenuItem(
                      value: value,
                      child: Text(
                        '${value[0].toUpperCase()}${value.substring(1)}',
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _save(
                      context,
                      () => settings.set(
                        AppSettingKeys.appearanceThemeMode,
                        value,
                      ),
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(('accent', accent)),
                initialValue: accent,
                decoration: const InputDecoration(labelText: 'Accent'),
                items: [
                  for (final entry in _accents.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  if (!_accents.containsKey(accent))
                    DropdownMenuItem(value: accent, child: Text(accent)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _save(
                      context,
                      () => settings.set(
                        AppSettingKeys.appearanceSeedColor,
                        value,
                      ),
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Applies immediately. System follows the brightness '
                'preference reported to Flutter, when supported by the host.',
              ),
              TextButton(
                onPressed: () => _save(context, () async {
                  await settings.reset(AppSettingKeys.appearanceThemeMode);
                  await settings.reset(AppSettingKeys.appearanceSeedColor);
                }),
                child: const Text('Reset appearance to defaults'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
