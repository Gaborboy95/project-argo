import 'dart:async';

import 'package:argo/app/app.dart';
import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/argo_render_recovery.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/app/pairing_request_overlay.dart';
import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/features/projection/projection_input_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'global requests own input above pushed routes and withdraw without navigating',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final service = _Connectivity();
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _Settings(),
      );
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final modules = AppModuleRegistry()
        ..register(
          AppModule(
            id: 'home',
            label: 'Home',
            icon: Icons.home,
            builder: (context, _) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: ProjectionInputScope(
                        active: true,
                        blocked: false,
                        child: Builder(
                          builder: (context) => Column(
                            children: [
                              Text(
                                'blocked:${ProjectionInputScope.blockedOf(context)}',
                              ),
                              TextField(
                                focusNode: focus,
                                decoration: const InputDecoration(
                                  labelText: 'Route input',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('Open route'),
              ),
            ),
          ),
        );
      await tester.pumpWidget(
        ArgoApp(
          environment: ArgoEnvironment(
            services: ServiceRegistry()
              ..register(settings)
              ..register<ConnectivityService>(service),
            moduleRegistry: modules,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open route'));
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(find.text('blocked:false'), findsOneWidget);
      expect(
        tester
            .element(find.byType(PairingRequestOverlay))
            .findAncestorWidgetOfExactType<ArgoRenderRecoveryScope>(),
        isNotNull,
      );
      service.emit(
        const ConnectivitySnapshot(
          available: true,
          daemonConnected: true,
          prompt: PairingPrompt(
            41,
            'hci2/AA:00:00:00:00:01',
            'A phone with a deliberately very long friendly name for portrait pairing approval',
            'Confirm matching passkey 123456',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bluetooth request'), findsOneWidget);
      expect(find.text('blocked:true'), findsOneWidget);
      expect(focus.hasFocus, isFalse);
      expect(find.textContaining('123456'), findsOneWidget);
      await tester.ensureVisible(find.text('Allow'));
      await tester.tap(find.text('Allow'));
      await tester.pump();
      expect(service.responses, [(41, true)]);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Allow'))
            .onPressed,
        isNull,
      );
      service.emit(
        const ConnectivitySnapshot(available: true, daemonConnected: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bluetooth request'), findsNothing);
      expect(find.text('Route input'), findsOneWidget);
      expect(find.text('blocked:false'), findsOneWidget);
      service.emit(
        const ConnectivitySnapshot(
          available: true,
          daemonConnected: true,
          prompt: PairingPrompt(
            42,
            'hci2/AA:00:00:00:00:02',
            'Another phone',
            'Authorize the service requested by this device',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('123456'), findsNothing);
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(service.responses, [(41, true), (42, false)]);
      service.emit(const ConnectivitySnapshot());
      await tester.pumpAndSettle();
      expect(find.text('Bluetooth request'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await service.changes.close();
      await settings.close();
    },
  );

  testWidgets(
    'failed or stalled decisions stay retryable and stale completions cannot affect another prompt',
    (tester) async {
      final service = _Connectivity();
      service.emit(
        const ConnectivitySnapshot(
          available: true,
          daemonConnected: true,
          prompt: PairingPrompt(
            1,
            'hci0/AA:00:00:00:00:01',
            'Phone one',
            'Allow pairing',
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              PairingRequestOverlay(service: service, child: child!),
          home: const Scaffold(body: Text('Background')),
        ),
      );
      service.fail = true;
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(
        find.text('Could not send the Bluetooth response. Try again.'),
        findsOneWidget,
      );
      service.fail = false;
      service.hold = Completer<void>();
      await tester.tap(find.text('Allow'));
      await tester.pump();
      await tester.pump(
        PairingRequestOverlay.decisionTimeout + const Duration(milliseconds: 1),
      );
      expect(find.textContaining('has not confirmed'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Allow'))
            .onPressed,
        isNotNull,
      );
      service.emit(
        const ConnectivitySnapshot(
          available: true,
          daemonConnected: true,
          prompt: PairingPrompt(
            2,
            'hci0/AA:00:00:00:00:02',
            'Phone two',
            'Authorize service',
          ),
        ),
      );
      await tester.pump();
      service.hold!.completeError(StateError('Old request lost'));
      await tester.pump();
      expect(find.text('Phone two'), findsOneWidget);
      expect(find.textContaining('has not confirmed'), findsNothing);
      expect(
        find.text('Could not send the Bluetooth response. Try again.'),
        findsNothing,
      );
      service.emit(
        const ConnectivitySnapshot(
          available: true,
          daemonConnected: false,
          prompt: PairingPrompt(
            2,
            'hci0/AA:00:00:00:00:02',
            'Phone two',
            'Stale prompt',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Bluetooth request'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await service.changes.close();
    },
  );
}

class _Settings implements SettingsStore {
  @override
  Future<SettingsDocument> read() async =>
      SettingsDocument(values: {AppSettingKeys.appearanceControlSize.id: 1.3});
  @override
  Future<void> write(SettingsDocument document) async {}
}

class _Connectivity implements ConnectivityService {
  ConnectivitySnapshot state = const ConnectivitySnapshot(
    available: true,
    daemonConnected: true,
  );
  final changes = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  final responses = <(int, bool)>[];
  bool fail = false;
  Completer<void>? hold;
  void emit(ConnectivitySnapshot next) {
    state = next;
    changes.add(next);
  }

  @override
  ConnectivitySnapshot get connectivity => state;
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => changes.stream;
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    expect(action, 'confirm');
    responses.add((prompt, accept));
    if (fail) throw StateError('Unavailable');
    if (hold != null) await hold!.future;
  }
}
