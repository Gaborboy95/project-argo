import 'package:flutter/material.dart';

import '../../core/camera/camera_service.dart';
import 'ihs_camera_surface.dart';

/// Navigation owns capture lifetime; IndexedStack retaining this page does not.
class CameraPage extends StatelessWidget {
  const CameraPage({super.key, required this.service});
  final CameraService? service;
  @override
  Widget build(BuildContext context) => StreamBuilder<CameraSnapshot>(
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
          (camera.width != null && camera.height != null && camera.height! > 0)
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
                    child: const IgnorePointer(
                      child: IhsCameraSurface(
                        key: ValueKey('rear-camera-native-view'),
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
                        'Rear camera • ${camera.state.name}${camera.error == null ? '' : ' — ${camera.error}'}',
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
  );
}

/// Retained pages must not infer activity from dispose or a live stream snapshot.
class CameraActivityScope extends InheritedWidget {
  const CameraActivityScope({
    super.key,
    required this.active,
    required super.child,
  });
  final bool active;
  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CameraActivityScope>()
          ?.active ??
      false;
  @override
  bool updateShouldNotify(CameraActivityScope oldWidget) =>
      active != oldWidget.active;
}
