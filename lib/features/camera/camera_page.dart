import 'parking_perception_panel.dart';
import 'recordings_page.dart';
import 'calibration_wizard.dart';

import 'package:flutter/material.dart';

import '../../core/camera/camera_service.dart';
import 'ihs_camera_surface.dart';

/// Navigation owns capture lifetime; IndexedStack retaining this page does not.
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
                  'Choose a capture device. Camera activation is manual.',
                ),
                if (camera.external && service is SurroundCameraControl)
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => CalibrationWizard(
                          service: service!,
                          control: service! as SurroundCameraControl,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.straighten),
                    label: const Text('Calibrate camera rig'),
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
                        ListTile(
                          leading: const Icon(Icons.videocam_outlined),
                          title: Text(device.displayName),
                          subtitle: Text(device.stableId),
                          trailing: const Text('Assign Rear'),
                          onTap: () async {
                            await service!.assign(
                              CameraRole.rear,
                              device.stableId,
                            );
                            if (context.mounted &&
                                CameraActivityScope.activeOf(context)) {
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
                          external: camera.external,
                        ),
                      ),
                    ),
                  ),
                ),
              if (camera.external &&
                  service is SurroundCameraControl &&
                  CameraActivityScope.activeOf(context))
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 12,
                  child: ParkingPerceptionPanel(
                    control: service! as SurroundCameraControl,
                    cameraId: camera
                        .assignments[camera.activeRole ?? CameraRole.rear],
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
                          '${camera.activeRole?.name ?? 'Rear'} camera • ${camera.state.name}${camera.error == null ? '' : ' — ${camera.error}'}',
                          maxLines: 2,
                          style: const TextStyle(
                            color: Colors.white,
                            backgroundColor: Colors.black87,
                          ),
                        ),
                      ),
                    if (camera.state == CameraStreamState.streaming)
                      const Spacer(),
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
                    if (camera.external && service is SurroundCameraControl)
                      PopupMenuButton<String>(
                        tooltip: 'Camera view',
                        icon: const Icon(Icons.view_in_ar, color: Colors.white),
                        onSelected: (value) async {
                          CameraActivityScope.manualSelection(context);
                          if (CameraRole.values.any(
                            (role) => role.name == value,
                          )) {
                            await service!.start(
                              CameraRole.values.byName(value),
                            );
                          } else {
                            final view = viewport.biggest;
                            final ratio = MediaQuery.devicePixelRatioOf(
                              context,
                            );
                            await (service! as SurroundCameraControl)
                                .selectView(
                                  value,
                                  width: (view.width * ratio).round(),
                                  height: (view.height * ratio).round(),
                                );
                          }
                        },
                        itemBuilder: (_) => [
                          for (final role in camera.assignments.keys)
                            PopupMenuItem(
                              value: role.name,
                              child: Text('Direct ${role.name}'),
                            ),
                          for (final mode in [
                            'rectified',
                            'top_down',
                            'bowl',
                            'split',
                          ])
                            PopupMenuItem(
                              value: mode,
                              child: Text(mode.replaceAll('_', ' ')),
                            ),
                        ],
                      ),
                    if (camera.external &&
                        service is SurroundCameraControl &&
                        camera.groups.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: 'Surround group',
                        icon: const Icon(
                          Icons.cameraswitch,
                          color: Colors.white,
                        ),
                        onSelected: (group) =>
                            (service! as SurroundCameraControl).selectView(
                              'top_down',
                              group: group,
                            ),
                        itemBuilder: (_) => [
                          for (final group in camera.groups.keys)
                            PopupMenuItem(value: group, child: Text(group)),
                        ],
                      ),
                    if (camera.external && service is SurroundCameraControl)
                      IconButton(
                        tooltip: 'Camera recordings',
                        icon: const Icon(
                          Icons.video_library,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CameraRecordingsPage(
                              service: service!,
                              control: service! as SurroundCameraControl,
                            ),
                          ),
                        ),
                      ),
                    if (camera.external && service is SurroundCameraControl)
                      IconButton(
                        tooltip: 'Calibrate camera rig',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CalibrationWizard(
                              service: service!,
                              control: service! as SurroundCameraControl,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.straighten, color: Colors.white),
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

/// Retained pages must not infer activity from dispose or a live stream snapshot.
class CameraActivityScope extends InheritedWidget {
  const CameraActivityScope({
    super.key,
    required this.active,
    this.onManualSelection,
    required super.child,
  });
  final bool active;
  final VoidCallback? onManualSelection;
  static void manualSelection(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CameraActivityScope>()
      ?.onManualSelection
      ?.call();
  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CameraActivityScope>()
          ?.active ??
      false;
  @override
  bool updateShouldNotify(CameraActivityScope oldWidget) =>
      active != oldWidget.active;
}
