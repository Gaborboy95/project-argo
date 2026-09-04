import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feature and core power code remain Veloce-independent', () async {
    final files = <File>[];
    for (final root in [
      Directory('lib/core/power'),
      Directory('lib/core/vehicle'),
      Directory('lib/features/vehicle'),
    ]) {
      await for (final entity in root.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) files.add(entity);
      }
    }

    expect(files, isNotEmpty);
    for (final file in files) {
      final source = await file.readAsString();
      expect(
        source,
        isNot(anyOf(contains('veloce_lua'), contains('integrations/veloce'))),
        reason: file.path,
      );
    }
  });

  test('core power service has no platform or Flutter dependencies', () async {
    await for (final entity in Directory(
      'lib/core/power',
    ).list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = await entity.readAsString();
      expect(
        source,
        isNot(
          anyOf(
            contains('package:flutter'),
            contains('dart:ui'),
            contains('dart:io'),
            contains('integrations/simulation'),
            contains('SocketCan'),
          ),
        ),
        reason: entity.path,
      );
    }
  });
}
