import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/app/navigation/app_modules.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves module registration order', () {
    final registry = AppModuleRegistry()
      ..register(_module('home'))
      ..register(_module('vehicle'))
      ..register(_module('settings'));

    expect(
      registry.modules.map((module) => module.id),
      orderedEquals(['home', 'vehicle', 'settings']),
    );
  });

  test('rejects duplicate module IDs', () {
    final registry = AppModuleRegistry()..register(_module('home'));

    expect(
      () => registry.register(_module('home')),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('App module "home" is already registered'),
        ),
      ),
    );
  });

  test('registers the built-in modules in navigation order', () {
    final registry = AppModuleRegistry();

    registerBuiltInAppModules(registry);

    expect(
      registry.modules.map((module) => module.id),
      orderedEquals([
        'home',
        'vehicle',
        'climate',
        'parking',
        'media',
        'settings',
      ]),
    );
  });

  testWidgets('module builder receives explicitly supplied services', (
    tester,
  ) async {
    final dependency = _ModuleDependency('ready');
    final services = ServiceRegistry()..register(dependency);
    final module = AppModule(
      id: 'test',
      label: 'Test',
      icon: Icons.circle_outlined,
      builder: (_, receivedServices) {
        expect(receivedServices, same(services));
        return Text(receivedServices.get<_ModuleDependency>().value);
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => module.builder(context, services)),
      ),
    );

    expect(find.text('ready'), findsOneWidget);
  });
}

AppModule _module(String id) => AppModule(
  id: id,
  label: id,
  icon: Icons.circle_outlined,
  builder: (_, _) => const SizedBox.shrink(),
);

final class _ModuleDependency {
  const _ModuleDependency(this.value);

  final String value;
}
