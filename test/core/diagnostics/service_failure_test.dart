import 'package:argo/core/diagnostics/service_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local cause is complete while copied diagnostics contain only safe categories', () {
    final secret =
        'pairing-secret phone-contact MFi credential vehicle-private ' * 100;
    final error = ServiceFailure(
      feature: secret,
      operation: secret,
      kind: FailureKind.rejected,
      summary: secret,
      cause: secret,
      recovery: secret,
    );
    expect(error.detail, secret);
    for (final part in [
      'pairing-secret',
      'phone-contact',
      'MFi',
      'credential',
      'vehicle-private',
    ]) {
      expect(error.copyDiagnostics, isNot(contains(part)));
    }
    expect(error.copyDiagnostics, contains('rejected'));
  });
}
