import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Set<String> importsFrom(String entry) {
  final found = <String>{};
  void visit(String path) {
    path = File(path).absolute.uri.normalizePath().toFilePath();
    if (!found.add(path)) return;
    final source = File(path).readAsStringSync();
    for (final match in RegExp(
      "(?:import|export) ['\"]([^'\"]+)['\"]",
    ).allMatches(source)) {
      final uri = match[1]!;
      if (uri.startsWith('dart:') ||
          (uri.startsWith('package:') && !uri.startsWith('package:argo/'))) {
        continue;
      }
      visit(
        uri.startsWith('package:argo/')
            ? 'lib/${uri.substring(13)}'
            : File(path).parent.uri.resolve(uri).toFilePath(),
      );
    }
  }

  visit(entry);
  return found;
}

void main() {
  test(
    'standard entrypoint excludes surround implementations transitively',
    () {
      final paths = importsFrom('lib/main.dart');
      for (final path in paths) {
        expect(path, isNot(contains('surround_camera_service.dart')));
        expect(path, isNot(contains('/calibration/')));
        expect(path, isNot(contains('model_manager_page.dart')));
        expect(path, isNot(contains('recordings_page.dart')));
      }
    },
  );
}
