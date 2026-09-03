import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/lifecycle/argo_lifecycle_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('exit, detach, and dispose request shutdown only once', (
    tester,
  ) async {
    final release = Completer<void>();
    var shutdownCalls = 0;
    final coordinator = AppLifecycleCoordinator()
      ..registerShutdown(
        name: 'resource',
        shutdown: () async {
          shutdownCalls++;
          await release.future;
        },
      );
    await tester.pumpWidget(
      ArgoLifecycleHost(coordinator: coordinator, child: const SizedBox()),
    );
    final state = tester.state<ArgoLifecycleHostState>(
      find.byType(ArgoLifecycleHost),
    );

    final exitRequest = state.didRequestAppExit();
    state.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pumpWidget(const SizedBox());
    release.complete();

    expect(await exitRequest, AppExitResponse.exit);
    await coordinator.shutdown();
    expect(shutdownCalls, 1);
  });
}
