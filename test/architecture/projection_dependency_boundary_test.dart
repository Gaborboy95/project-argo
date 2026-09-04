import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('core projection is platform and protocol independent', () {
    final source = _readDart('lib/core/projection');
    expect(source, isNot(contains('integrations/')));
    expect(source, isNot(contains('veloce')));
    expect(source, isNot(contains('AndroidAutoProjectionBackend')));
    expect(source, isNot(contains('PipeWire')));
    expect(source, isNot(contains('package:flutter/')));
  });

  test('projection feature depends only on generic projection APIs', () {
    final source = [
      _readDart('lib/features/projection'),
      File('lib/features/media/media_page.dart').readAsStringSync(),
    ].join('\n');
    expect(source, isNot(contains('integrations/projection')));
    expect(source, isNot(contains('android_auto')));
    expect(source, isNot(contains('veloce')));
  });

  test('repository contains no embedded private key or certificate', () {
    final source = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .followedBy(
          Directory('native')
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => !file.path.contains('.dart_tool')),
        )
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(source, isNot(contains('-----BEGIN PRIVATE KEY-----')));
    expect(source, isNot(contains('-----BEGIN CERTIFICATE-----')));
  });
}

String _readDart(String path) =>
    Directory(path)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');
