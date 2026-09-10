import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/lifecycle/application_exit_service.dart';
import 'package:argo/core/lifecycle/managed_application.dart';
import 'package:flutter_test/flutter_test.dart';

class Backend implements ConnectivityService {
  @override
  ConnectivitySnapshot connectivity = const ConnectivitySnapshot(
    daemonConnected: true,
  );
  final changes = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => changes.stream;
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    expect(action, 'stopAll');
    changes.add(ConnectivitySnapshot(daemonConnected: true, stopped: prompt));
  }
}

void main() {
  test('private control waits for rendered IPC client and acknowledges ordered cleanup', () async {
    final root = await Directory.systemTemp.createTemp('argo-managed-');
    final backend = Backend();
    final marker = File('${root.path}/app.json');
    final socketPath = '${root.path}/app.sock';
    final managed = ManagedApplication({
      'ARGO_MANAGED_SOCKET': socketPath,
      'ARGO_MANAGED_RESULT': marker.path,
      'INVOCATION_ID': 'test-invocation',
    }, backend);
    final order = <String>[];
    final lifecycle = AppLifecycleCoordinator()
      ..registerShutdown(
        name: 'owned',
        shutdown: () => order.add('owned cleanup'),
      );
    final service = ApplicationExitService(
      lifecycle: lifecycle,
      connectivity: backend,
      onCleanExit: managed.completed,
      exitProcess: () => order.add('exit'),
    );
    await managed.start(service);
    Future<Map<String, dynamic>?> request(String command) async {
      final client = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      client.write('$command\n');
      final data = await utf8.decoder
          .bind(client)
          .join()
          .timeout(const Duration(seconds: 3));
      client.destroy();
      return data.isEmpty ? null : jsonDecode(data) as Map<String, dynamic>;
    }

    expect((await request('status'))?['ready'], false);
    managed.rendered = true;
    expect((await request('status'))?['ready'], true);
    expect((await request('not a command'))?['error'], isNotNull);
    expect(marker.existsSync(), false);
    await request('quit');
    expect(order, ['owned cleanup', 'exit']);
    expect(
      jsonDecode(await marker.readAsString()),
      containsPair('invocation', 'test-invocation'),
    );
    expect(
      jsonDecode(await marker.readAsString()),
      containsPair('result', 'clean'),
    );
    await managed.close();
    await backend.changes.close();
    await root.delete(recursive: true);
  });
}
