import 'package:flutter/material.dart';

import 'shell/app_shell.dart';

class ArgoApp extends StatelessWidget {
  const ArgoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Project Argo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const AppShell(),
    );
  }
}
