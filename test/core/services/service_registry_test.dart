import 'package:argo/core/services/service_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers and retrieves a service by type', () {
    final registry = ServiceRegistry();
    final service = _ExampleService();

    registry.register(service);

    expect(registry.get<_ExampleService>(), same(service));
    expect(registry.contains<_ExampleService>(), isTrue);
  });

  test('rejects duplicate service types', () {
    final registry = ServiceRegistry()..register(_ExampleService());

    expect(
      () => registry.register(_ExampleService()),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('_ExampleService is already registered'),
        ),
      ),
    );
  });

  test('fails clearly when a required service is missing', () {
    final registry = ServiceRegistry();

    expect(
      () => registry.get<_ExampleService>(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Required service _ExampleService is not registered'),
        ),
      ),
    );
  });
}

final class _ExampleService {}
