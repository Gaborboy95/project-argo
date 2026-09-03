import 'dart:io';

import 'package:flutter/material.dart';

import 'app/bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    await bootstrapArgoApplication(processEnvironment: Platform.environment),
  );
}
