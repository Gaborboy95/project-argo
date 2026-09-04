import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'core and feature audio code has no Veloce or PipeWire dependency',
    () async {
      final files = <File>[
        ...Directory('lib/core/audio')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
        File('lib/features/settings/settings_page.dart'),
      ];

      for (final file in files) {
        final source = await file.readAsString();
        expect(
          source,
          isNot(contains('veloce_lua')),
          reason: '${file.path} must remain Veloce-independent',
        );
        expect(
          source,
          isNot(contains('integrations/veloce')),
          reason: '${file.path} must not import a Veloce adapter',
        );
        expect(
          source,
          isNot(contains('pipewire_audio_backend')),
          reason: '${file.path} must remain backend-independent',
        );
      }
    },
  );

  test('public Argo audio contains no manufacturer identifiers', () async {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final source = (await file.readAsString()).toLowerCase();
      expect(source, isNot(contains('phaeton')));
      expect(source, isNot(contains('toyota')));
    }
  });
}
