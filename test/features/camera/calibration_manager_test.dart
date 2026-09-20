import 'package:argo/features/camera/calibration/calibration_preview.dart';
import 'package:argo/features/camera/ihs_camera_surface.dart';
import 'package:argo/features/camera/calibration/marker_review_view.dart';
import 'package:argo/core/camera/calibration_manager.dart';
import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/camera/parking_model_service.dart';
import 'package:argo/features/camera/calibration/calibration_home.dart';
import 'package:argo/features/camera/calibration/lens_profile_selector.dart';
import 'package:argo/features/camera/calibration/bench_lens_calibration_page.dart';
import 'package:argo/features/settings/models/model_manager_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'camera_navigation_test.dart' show CameraFixture;

class Engine implements SurroundCameraControl {
  final calls = <Map<String, Object?>>[];
  Map<String, Object?> pending = {};
  Map<String, dynamic>? draft;
  Map<String, dynamic>? bench;
  @override
  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, Object?> args = const {},
    bool admin = false,
  ]) async {
    calls.add({'operation': op, ...args});
    if (op == 'worker') {
      pending = Map<String, Object?>.from(args['request'] as Map);
      return {'job_id': 1};
    }
    if (op == 'job_status') {
      return {
        'state': 'complete',
        'result': {'ok': true, 'result': answer(pending)},
      };
    }
    if (op == 'models') return {'models': [], 'selected': null, 'progress': {}};
    return {};
  }

  Map<String, dynamic> answer(Map<String, Object?> req) => switch (req['op']) {
    'draft_get' => {'draft': draft},
    'draft_save' => {'draft': draft = req['draft'] as Map<String, dynamic>},
    'profile_list' => {
      'profiles': [
        {
          'id': 'a' * 64,
          'display_name': 'Wide lens',
          'image_size': [1920, 1080],
          'lens_model': 'opencv_omnidir',
          'calibrated_ns': 1,
          'source': 'bench',
          'diagnostics': {'rms_px': .5},
        },
      ],
    },
    'profile_apply' => {'cameras': req['cameras']},
    'bench_get' => {'bench': bench},
    'bench_save' => {
      'profile': {'id': 'b' * 64},
    },
    _ => {},
  };
  @override
  Future<void> selectView(
    String mode, {
    String? group,
    int? width,
    int? height,
  }) async {}
}

void main() {
  testWidgets(
    'calibration native preview fits live and static image sizes without recreating the view',
    (tester) async {
      final camera = CameraFixture();
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          return call.method == 'create' ? (call.arguments as Map)['id'] : null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [CalibrationPreview(service: camera)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final size in [
        const Size(1920, 1080),
        const Size(640, 480),
        const Size(256, 256),
      ]) {
        camera.current = CameraSnapshot(
          available: true,
          width: size.width.toInt(),
          height: size.height.toInt(),
        );
        camera.events.add(camera.current);
        await tester.pumpAndSettle();
        final viewport = tester.getSize(find.byType(IhsCameraSurface));
        expect(viewport.aspectRatio, closeTo(size.aspectRatio, .00001));
        expect(viewport.height, lessThanOrEqualTo(360));
      }
      expect(calls.where((c) => c.method == 'create'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await camera.close();
    },
  );

  test('mode uses daemon stream list without guessing a missing mode', () {
    final camera = CameraFixture();
    camera.current = const CameraSnapshot(
      details: {
        'streams': [
          {
            'camera_id': 'a',
            'mode': {'width': 1920, 'height': 1080, 'format': 'MJPEG'},
          },
        ],
      },
    );
    final manager = CalibrationManager(camera, Engine());
    expect(manager.mode('a')['width'], 1920);
    expect(manager.mode('missing').containsKey('width'), false);
  });
  testWidgets(
    'reopen draft offers continue without a session ID or activation',
    (tester) async {
      final engine = Engine()
        ..draft = {
          'schema': 'surround-camera.installation-draft',
          'schema_major': 1,
          'step': 2,
          'cameras': <String, dynamic>{},
          'observations': <String, dynamic>{},
          'mats': <String, dynamic>{},
          'vehicle': <String, dynamic>{},
        };
      final camera = CameraFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: CalibrationHome(service: camera, control: engine),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Continue current calibration'), findsOneWidget);
      await tester.tap(find.text('Continue current calibration'));
      await tester.pumpAndSettle();
      expect(find.text('Vehicle length (m)'), findsOneWidget);
      expect(find.textContaining('session ID'), findsNothing);
      expect(
        engine.calls.any(
          (c) =>
              c['request'] is Map && (c['request'] as Map)['op'] == 'activate',
        ),
        false,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await camera.close();
    },
  );
  testWidgets(
    'profile selection sends selected cameras to engine and offers export',
    (tester) async {
      final camera = CameraFixture();
      final engine = Engine();
      Map<String, dynamic>? applied;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LensProfileSelector(
                manager: CalibrationManager(camera, engine),
                cameras: {
                  'front-id': {'role': 'front'},
                  'rear-id': {'role': 'rear'},
                },
                applied: (c) => applied = c,
                bench: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wide lens • [1920, 1080]'));
      await tester.pumpAndSettle();
      expect(find.text('Export lens profile'), findsOneWidget);
      await tester.tap(find.text('rear • rear-id'));
      await tester.pump();
      await tester.tap(find.text('Use profile for selected matching cameras'));
      await tester.pumpAndSettle();
      expect(applied!.keys, ['front-id']);
      await tester.pumpWidget(const SizedBox());
      await camera.close();
    },
  );
  testWidgets('bench resumes solved lens and saves a named profile', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async =>
          call.method == 'create' ? (call.arguments as Map)['id'] : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    final camera = CameraFixture();
    final engine = Engine()
      ..bench = {
        'camera_id': 'a',
        'lens_model': 'opencv_omnidir',
        'observations': [],
        'coverage_cells': [],
        'solution': {
          'diagnostics': {'rms_px': .4},
        },
      };
    await tester.pumpWidget(
      MaterialApp(
        home: BenchLensCalibrationPage(
          manager: CalibrationManager(camera, engine),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Save as lens profile'), 250);
    await tester.enterText(find.byType(TextField), 'My measured lens');
    await tester.tap(find.text('Save as lens profile'));
    await tester.pumpAndSettle();
    expect(
      engine.calls.any(
        (c) =>
            c['request'] is Map &&
            (c['request'] as Map)['op'] == 'bench_save' &&
            (c['request'] as Map)['name'] == 'My measured lens',
      ),
      true,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await camera.close();
  });
  testWidgets(
    'model manager has no manifest input and never benchmarks automatically',
    (tester) async {
      final engine = Engine();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelManagerPage(service: ParkingModelService(engine)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('AI & Models'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(
        engine.calls
            .where((c) => c['operation'] == 'models')
            .every((c) => c['action'] == 'status'),
        true,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'frozen marker image is event driven and reset restores manual placement gate',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async =>
            call.method == 'create' ? (call.arguments as Map)['id'] : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      final camera = CameraFixture(), engine = Engine();
      final observation = <String, dynamic>{
        'image': '/engine/shot.ppm',
        'image_size': [640, 480],
        'corners': [
          [10, 10],
          [20, 20],
          [30, 30],
          [40, 40],
          [50, 50],
          [60, 60],
        ],
        'original_corners': [
          [10, 10],
          [20, 20],
          [30, 30],
          [40, 40],
          [50, 50],
          [60, 60],
        ],
        'manual_seed': true,
        'manual_required': [0, 1, 2, 3, 4, 5],
        'disabled': [],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MarkerReviewView(
                manager: CalibrationManager(camera, engine),
                observation: observation,
                changed: () {},
                redetect: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.calls.where((c) => c['operation'] == 'present').length, 1);
      await tester.pump(const Duration(seconds: 30));
      expect(engine.calls.where((c) => c['operation'] == 'present').length, 1);
      final surface = find.byKey(const ValueKey('marker-image-interaction'));
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect((observation['manual_required'] as List).contains(0), false);
      await tester.ensureVisible(find.text('Reset point'));
      await tester.tap(find.text('Reset point'));
      await tester.pump();
      expect((observation['manual_required'] as List).contains(0), true);
      await tester.ensureVisible(find.text('Undo correction'));
      await tester.tap(find.text('Undo correction'));
      await tester.pump();
      expect((observation['manual_required'] as List).contains(0), false);
      await tester.ensureVisible(find.text('Reset camera points'));
      await tester.tap(find.text('Reset camera points'));
      await tester.pump();
      expect((observation['manual_required'] as List).contains(0), true);
      await tester.pumpWidget(const SizedBox());
      await camera.close();
    },
  );
}
