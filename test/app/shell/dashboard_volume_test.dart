import 'dart:async';

import 'package:argo/app/shell/dashboard_volume.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_snapshot.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'relative live volume coalesces, commits outside release and cancels without muting',
    (tester) async {
      final audio = _Audio();
      double? indicator;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 64,
                height: 96,
                child: DashboardVolume(
                  audio: audio,
                  scale: 1,
                  onIndicator: (v) => indicator = v,
                ),
              ),
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(DashboardVolume));
      final gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 100));
      expect(audio.current.masterVolume, .5);
      expect(indicator, isNull);
      for (var i = 1; i <= 100; i++) {
        await gesture.moveTo(center - Offset(0, i.toDouble()));
      }
      expect(audio.writes, 0);
      await tester.pump(const Duration(milliseconds: 40));
      expect(audio.writes, 1);
      expect(audio.current.masterVolume, greaterThan(.5));
      expect(indicator, audio.current.masterVolume);
      await gesture.moveTo(center - const Offset(0, 500));
      await gesture
          .up(); // Outside its hit box, final level commits immediately.
      await tester.pump();
      expect(audio.current.masterVolume, 1);
      expect(indicator, isNull);
      expect(audio.current.muted, isFalse);
      final cancel = await tester.startGesture(center);
      await cancel.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 40));
      final live = audio.current.masterVolume;
      await cancel.cancel();
      await tester.pump();
      expect(audio.current.masterVolume, live);
      expect(audio.current.muted, isFalse);
      expect(indicator, isNull);
      await tester.tap(find.byType(DashboardVolume));
      await tester.pump();
      expect(audio.current.muted, isTrue);
      audio.hold = Completer<void>();
      final delayed = await tester.startGesture(center);
      await delayed.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 40));
      final inFlightWrites = audio.writes;
      for (var i = 40; i < 100; i++) {
        await delayed.moveTo(center + Offset(0, i.toDouble()));
      }
      await tester.pump(const Duration(milliseconds: 120));
      expect(audio.writes, inFlightWrites); // No queue of backend calls.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(indicator, isNull);
      audio.hold!.complete();
      await tester.pump();
      expect(
        audio.writes,
        inFlightWrites + 1,
      ); // Only the latest target commits.
      expect(audio.current.muted, isTrue);
      await delayed.up(); // Late release cannot toggle mute after focus loss.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(audio.current.muted, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}

// Widget contract fixture; DefaultAudioService/backend persistence has its own
// existing tests. No real host volume or focus changes are made here.
class _Audio implements AudioService {
  double volume = .5;
  bool muted = false;
  int writes = 0;
  Completer<void>? hold;
  @override
  AudioSnapshot get current => AudioSnapshot(
    masterVolume: volume,
    muted: muted,
    balance: 0,
    fader: 0,
    equalizer: const AudioEqualizer(),
    backendAvailable: true,
    capabilities: const AudioBackendCapabilities(
      masterVolume: true,
      mute: true,
    ),
    selectedOutput: 'test-output',
    activeSources: const [],
    effectiveSourceGains: const {},
    focusSources: const [],
  );
  @override
  Stream<AudioSnapshot> get changes => const Stream.empty();
  @override
  Future<void> setMasterVolume(double value) async {
    writes++;
    volume = value;
    await hold?.future;
  }

  @override
  Future<void> toggleMuted() async {
    muted = !muted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
