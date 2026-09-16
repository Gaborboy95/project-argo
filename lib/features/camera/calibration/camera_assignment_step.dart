import 'package:flutter/material.dart';

import '../../../core/camera/calibration_manager.dart';
import '../../../core/camera/camera_service.dart';
import 'calibration_preview.dart';

class CameraAssignmentStep extends StatelessWidget {
  const CameraAssignmentStep({
    super.key,
    required this.manager,
    required this.changed,
    required this.checkMats,
    required this.cameras,
  });
  final Map<String, dynamic> cameras;
  final CalibrationManager manager;
  final Future<void> Function() changed, checkMats;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text(
        'Assign the physical cameras, then check each live image. Devices without a connected camera may provide no usable signal.',
      ),
      StreamBuilder<CameraSnapshot>(
        stream: manager.service.changes,
        initialData: manager.service.current,
        builder: (context, snapshot) {
          final state = snapshot.data!;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final role in CameraRole.values)
                SizedBox(
                  width: 280,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Text(
                            role.name.toUpperCase(),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          DropdownButton<String>(
                            isExpanded: true,
                            value:
                                state.devices.any(
                                  (d) => d.stableId == state.assignments[role],
                                )
                                ? state.assignments[role]
                                : null,
                            hint: const Text('Choose capture device'),
                            items: [
                              for (final device in state.devices)
                                DropdownMenuItem(
                                  value: device.stableId,
                                  child: Text(
                                    device.displayName,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (id) async {
                              if (id != null) {
                                try {
                                  final other = state.assignments.entries
                                      .where(
                                        (e) => e.value == id && e.key != role,
                                      )
                                      .firstOrNull;
                                  final old = state.assignments[role];
                                  if (other != null && old != null) {
                                    await manager.control.command('assign', {
                                      'role': role.name,
                                      'camera_id': id,
                                      'swap_with': other.key.name,
                                      'expected_old': old,
                                    }, true);
                                    await manager.service.refresh();
                                  } else {
                                    await manager.service.assign(role, id);
                                  }
                                  await changed();
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('$e')),
                                    );
                                  }
                                }
                              }
                            },
                          ),
                          Text(
                            '${state.assignments[role] ?? 'Unassigned'}\n${manager.mode(state.assignments[role] ?? '')}',
                          ),
                          Text(
                            'Lens: ${cameras[state.assignments[role]]?['lens_profile_id'] ?? 'Not selected'}\nStatus: ${cameras[state.assignments[role]]?['state'] ?? 'Uncalibrated'}',
                          ),
                          TextButton(
                            onPressed: state.assignments[role] == null
                                ? null
                                : () async {
                                    await manager.service.start(role);
                                    await changed();
                                  },
                            child: const Text('Show live image'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      CalibrationPreview(service: manager.service),
      TextButton(
        onPressed: () async {
          try {
            await manager.control.selectView(
              'multi_camera',
              width: 640,
              height: 480,
            );
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('$error')));
            }
          }
        },
        child: const Text('Show all live camera views'),
      ),
      TextButton(
        onPressed: checkMats,
        child: const Text('Capture all views to check mats'),
      ),
    ],
  );
}
