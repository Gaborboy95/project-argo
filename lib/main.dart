import 'package:flutter/material.dart';

import 'app/app.dart';
import 'integrations/veloce/veloce_runtime.dart';
import 'integrations/veloce/veloce_runtime_lifecycle.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final veloceRuntime = await VeloceRuntime.start();
  runApp(
    VeloceRuntimeLifecycle(runtime: veloceRuntime, child: const ArgoApp()),
  );
}
