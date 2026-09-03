import 'package:argo/core/runtime/argo_runtime_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to production', () {
    expect(
      ArgoRuntimeMode.fromEnvironment(const {}),
      ArgoRuntimeMode.production,
    );
  });

  test('parses explicit production and simulation modes', () {
    expect(
      ArgoRuntimeMode.fromEnvironment(const {'ARGO_MODE': 'production'}),
      ArgoRuntimeMode.production,
    );
    expect(
      ArgoRuntimeMode.fromEnvironment(const {'ARGO_MODE': 'SIMULATION'}),
      ArgoRuntimeMode.simulation,
    );
  });

  test('rejects invalid and empty modes clearly', () {
    for (final value in ['', 'development', 'auto']) {
      expect(
        () => ArgoRuntimeMode.fromEnvironment({'ARGO_MODE': value}),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'ARGO_MODE',
          ),
        ),
      );
    }
  });
}
