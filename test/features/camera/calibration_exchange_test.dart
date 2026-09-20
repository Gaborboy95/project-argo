import 'dart:io';

import 'package:argo/features/camera/calibration/exchange_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('argo-exchange-'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test('reads a valid JSON object without modifying its bytes', () async {
    final file = File('${directory.path}/lens.json');
    await file.writeAsString('{"schema":"surround-camera.lens-profile"}\n');
    expect(await CalibrationExchange.readJson(file), await file.readAsBytes());
  });
  test('rejects oversized and malformed input', () async {
    final file = File('${directory.path}/bad.json');
    await file.writeAsString('[]');
    await expectLater(
      CalibrationExchange.readJson(file),
      throwsFormatException,
    );
    await file.writeAsString('{broken');
    await expectLater(
      CalibrationExchange.readJson(file),
      throwsFormatException,
    );
    await file.writeAsBytes(List.filled(CalibrationExchange.maxBytes + 1, 32));
    await expectLater(
      CalibrationExchange.readJson(file),
      throwsFormatException,
    );
  });
  test('rejects links and directories', () async {
    final file = File('${directory.path}/lens.json');
    await file.writeAsString('{}');
    final link = Link('${directory.path}/link.json');
    await link.create(file.path);
    await expectLater(
      CalibrationExchange.readJson(File(link.path)),
      throwsFormatException,
    );
    await expectLater(
      CalibrationExchange.readJson(File(directory.path)),
      throwsFormatException,
    );
  });
}
