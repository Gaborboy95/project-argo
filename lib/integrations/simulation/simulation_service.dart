import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import 'simulation_scenario.dart';

typedef SimulationPlaybackErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Controls development-only input while leaving Veloce as the data path.
///
/// The service references, but does not own, its CAN provider or vehicle bus.
final class SimulationService {
  SimulationService({
    required this._canProvider,
    required this._vehicleDataBus,
    this._onPlaybackError,
  });

  static const sourceOwnerId = 'argo.simulation';

  final InMemoryCanProvider _canProvider;
  final VehicleDataBus _vehicleDataBus;
  final SimulationPlaybackErrorHandler? _onPlaybackError;
  SimulationScenario? _scenario;
  _ScenarioRun? _activeRun;
  Future<void>? _playbackFuture;

  bool get isScenarioRunning => _activeRun != null;
  SimulationScenario? get scenario => _scenario;
  Future<void> get scenarioCompletion =>
      _playbackFuture ?? Future<void>.value();

  CanInjectionResult injectCanFrame(CanFrame frame) {
    return _canProvider.inject(frame);
  }

  VehiclePublishResult publishVehicleValue(String key, StructuredValue value) {
    return _vehicleDataBus.publish(key, value, sourcePluginId: sourceOwnerId);
  }

  Future<void> startScenario(SimulationScenario scenario) async {
    await stopScenario();
    _scenario = scenario;
    final run = _ScenarioRun();
    _activeRun = run;
    final playback = _play(scenario, run);
    _playbackFuture = playback;
    unawaited(
      playback.catchError((Object error, StackTrace stackTrace) {
        _reportPlaybackError(error, stackTrace);
      }),
    );
  }

  Future<void> stopScenario() async {
    final run = _activeRun;
    if (run == null) return;
    run.cancel();
    await (_playbackFuture ?? Future<void>.value());
  }

  Future<void> restartScenario() async {
    final current = _scenario;
    if (current == null) {
      throw StateError('No simulation scenario has been started.');
    }
    await stopScenario();
    await startScenario(current);
  }

  Future<void> _play(SimulationScenario scenario, _ScenarioRun run) async {
    try {
      if (scenario.events.isEmpty) return;
      do {
        run.beginCycle();
        for (final event in scenario.events) {
          if (!await run.waitUntil(event.atMs)) return;
          _dispatch(event);
        }
        if (scenario.loop && scenario.events.last.atMs == 0) {
          if (!await run.waitUntil(1)) return;
        }
      } while (scenario.loop && !run.cancelled);
    } finally {
      run.finish();
      if (identical(_activeRun, run)) {
        _activeRun = null;
      }
    }
  }

  void _dispatch(SimulationScenarioEvent event) {
    switch (event) {
      case SimulationCanEvent(:final frame):
        injectCanFrame(frame);
      case SimulationVehicleEvent(:final key, :final value):
        publishVehicleValue(key, value);
    }
  }

  void _reportPlaybackError(Object error, StackTrace stackTrace) {
    final handler = _onPlaybackError;
    if (handler != null) {
      try {
        handler(error, stackTrace);
      } on Object {
        // Diagnostics must not create a second playback failure.
      }
      return;
    }
    stderr.writeln('[Argo simulation] playback failed: $error');
    developer.log(
      'Simulation playback failed.',
      name: 'argo.simulation',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

final class _ScenarioRun {
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;
  Completer<void>? _waiter;
  var cancelled = false;

  void beginCycle() {
    _stopwatch
      ..reset()
      ..start();
  }

  Future<bool> waitUntil(int targetMilliseconds) async {
    final targetMicroseconds = targetMilliseconds * 1000;
    while (!cancelled) {
      final remaining = targetMicroseconds - _stopwatch.elapsedMicroseconds;
      if (remaining <= 0) return true;

      final waiter = Completer<void>();
      _waiter = waiter;
      _timer = Timer(Duration(microseconds: remaining), () {
        if (!waiter.isCompleted) waiter.complete();
      });
      await waiter.future;
      if (identical(_waiter, waiter)) {
        _waiter = null;
        _timer = null;
      }
    }
    return false;
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _timer?.cancel();
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _stopwatch.stop();
  }

  void finish() {
    _timer?.cancel();
    _timer = null;
    _waiter = null;
    _stopwatch.stop();
  }
}
