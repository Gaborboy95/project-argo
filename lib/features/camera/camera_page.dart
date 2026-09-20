import '../../core/diagnostics/service_failure.dart';
import '../shared/status_panel.dart';
import '../../core/camera/basic_camera_control.dart';
import '../shared/argo_components.dart';
import 'basic_camera_settings.dart';
import 'camera_activity_scope.dart';
export 'camera_activity_scope.dart';

import 'package:flutter/material.dart';

import '../../core/camera/camera_service.dart';
import 'ihs_camera_surface.dart';

/// Navigation owns display subscriptions; recording and perception stay in the engine.
class CameraPage extends StatelessWidget {
  const CameraPage({super.key, required this.service});
  final CameraService? service;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) => StreamBuilder<CameraSnapshot>(
      stream: service?.changes,
      initialData: service?.current ?? const CameraSnapshot(),
      builder: (context, update) {
        final camera = update.data!;
        if (!camera.available) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                camera.error ?? 'Camera requires a camera-capable release.',
              ),
            ),
          );
        }
        if (camera.assignments[CameraRole.rear] == null) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Rear camera',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const Text(
                  'Choose a capture device. Automatic reverse requires fresh vehicle signals. Manual preview remains available.',
                ),
                TextButton.icon(
                  onPressed: service!.refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh devices'),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final device in camera.devices)
                        ArgoDeviceChoice(
                          name: device.displayName,
                          identifier: device.stableId,
                          onSelect: () async {
                            await service!.assign(
                              CameraRole.rear,
                              device.stableId,
                            );
                            if (context.mounted &&
                                CameraActivityScope.activeOf(context) &&
                                CameraActivityScope.manualSelection(context)) {
                              await service!.start(CameraRole.rear);
                            }
                          },
                        ),
                      if (camera.devices.isEmpty)
                        const ListTile(
                          title: Text('No accessible V4L2 capture devices'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        final aspect =
            (camera.width != null &&
                camera.height != null &&
                camera.height! > 0)
            ? camera.width! / camera.height!
            : 16 / 9;
        return ColoredBox(
          color: Colors.black,
          child: Stack(
            children: [
              if (CameraActivityScope.activeOf(context))
                Positioned.fill(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: aspect,
                      child: IgnorePointer(
                        child: IhsCameraSurface(
                          key: const ValueKey('rear-camera-native-view'),
                          external: false,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 12,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    if (camera.state != CameraStreamState.streaming)
                      Expanded(
                        child: Text(
                          '${camera.activeRole?.name ?? 'Rear'} camera • ${camera.state.name}',
                          maxLines: 2,
                          style: const TextStyle(
                            color: Colors.white,
                            backgroundColor: Colors.black87,
                          ),
                        ),
                      ),
                    if (camera.state == CameraStreamState.streaming)
                      Expanded(child: const SizedBox()),
                    if (camera.error case final error?)
                      TextButton(
                        onPressed: () {
                          if (!CameraActivityScope.manualSelection(context)) {
                            return;
                          }
                          showArgoFailure(
                            context,
                            ServiceFailure(
                              feature: 'camera',
                              operation: 'observe',
                              kind: FailureKind.unavailableDevice,
                              summary: 'Camera view is unavailable',
                              cause: error,
                              retryable: true,
                            ),
                          );
                        },
                        child: const Text('Details'),
                      ),
                    if ({
                      CameraStreamState.failed,
                      CameraStreamState.disconnected,
                      CameraStreamState.stale,
                      CameraStreamState.idle,
                    }.contains(camera.state))
                      TextButton(
                        onPressed: () => service!.start(CameraRole.rear),
                        child: const Text('Retry'),
                      ),
                    if (service case final BasicCameraControl control)
                      IconButton(
                        tooltip: 'Capture and orientation',
                        icon: const Icon(Icons.tune, color: Colors.white),
                        onPressed: () async {
                          if (!CameraActivityScope.manualSelection(context)) {
                            return;
                          }
                          await showBasicCameraSettings(
                            context,
                            service!,
                            control,
                          );
                          if (context.mounted &&
                              CameraActivityScope.activeOf(context) &&
                              CameraActivityScope.manualSelection(context)) {
                            await service!.start(CameraRole.rear);
                          }
                        },
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Rear camera device',
                      icon: const Icon(
                        Icons.settings_input_component,
                        color: Colors.white,
                      ),
                      onSelected: (id) async {
                        await service!.assign(CameraRole.rear, id);
                        if (context.mounted &&
                            CameraActivityScope.activeOf(context)) {
                          await service!.start(CameraRole.rear);
                        }
                      },
                      itemBuilder: (_) => [
                        for (final d in camera.devices)
                          PopupMenuItem(
                            value: d.stableId,
                            child: Text(d.displayName),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
