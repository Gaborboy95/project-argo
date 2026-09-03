import 'dart:io';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'integrations/veloce/socket_can_provider.dart';
import 'integrations/veloce/veloce_runtime.dart';
import 'integrations/veloce/veloce_runtime_lifecycle.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final veloceConfiguration = VeloceRuntimeConfiguration.fromEnvironment(
    environment: environment,
  );
  final socketCanConfiguration = SocketCanConfiguration.fromEnvironment(
    environment,
  );
  final canProvider = socketCanConfiguration == null
      ? null
      : await SocketCanProvider.start(socketCanConfiguration);
  final veloceRuntime = await VeloceRuntime.start(
    configuration: veloceConfiguration,
    canProvider: canProvider,
    canProviderDescription: socketCanConfiguration == null
        ? null
        : 'SocketCAN(interface=${socketCanConfiguration.interfaceName}, '
              'bus=${socketCanConfiguration.logicalBus}, '
              'writes=${socketCanConfiguration.writesEnabled})',
  );
  runApp(
    VeloceRuntimeLifecycle(runtime: veloceRuntime, child: const ArgoApp()),
  );
}
