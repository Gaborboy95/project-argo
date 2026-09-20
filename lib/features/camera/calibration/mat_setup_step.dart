import '../../../core/camera/measured_mat_layout.dart';
import '../../shared/argo_components.dart';

import 'package:flutter/material.dart';

import 'calibration_fields.dart';

class MatSetupStep extends StatefulWidget {
  const MatSetupStep({super.key, required this.draft, required this.changed});
  final Map<String, dynamic> draft;
  final VoidCallback changed;
  @override
  State<MatSetupStep> createState() => _MatSetupState();
}

class _MatSetupState extends State<MatSetupStep> {
  @override
  Widget build(BuildContext context) {
    final mats = widget.draft['mats'] as Map<String, dynamic>;
    final template =
        widget.draft['template'] as String? ?? 'four_checkerboards';
    final roles = template == 'front_rear_checkerboards'
        ? const ['front', 'rear']
        : const ['front', 'rear', 'left', 'right'];
    final configured = (widget.draft['cameras'] as Map? ?? {}).values
        .map((v) => (v as Map)['role'])
        .whereType<String>()
        .toSet();
    final cameraRoles = configured.isEmpty ? roles : configured.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButton<String>(
          value: widget.draft['template'] as String? ?? 'four_checkerboards',
          items: const [
            DropdownMenuItem(
              value: 'four_checkerboards',
              child: Text('Four checkerboard mats'),
            ),
            DropdownMenuItem(
              value: 'front_rear_checkerboards',
              child: Text('Front / rear checkerboard mats'),
            ),
            DropdownMenuItem(
              value: 'custom_checkerboards',
              child: Text('Custom measured layout'),
            ),
          ],
          onChanged: (v) {
            setState(() => widget.draft['template'] = v);
            widget.changed();
          },
        ),
        const Text(
          'Count inner corners, not black squares. Lay mats flat on the same ground plane, with the nearest row parallel to the bumper or body. Measure from the bumper/body to that inner-corner row. Confirm the labelled first corner during review.',
        ),

        for (final role in cameraRoles)
          Row(
            children: [
              Text('$role camera sees: '),
              DropdownButton<String>(
                value:
                    roles.contains(
                      (widget.draft['mat_assignments'] as Map?)?[role] ?? role,
                    )
                    ? ((widget.draft['mat_assignments'] as Map?)?[role]
                              as String? ??
                          role)
                    : null,
                hint: const Text('Choose mat'),
                items: [
                  for (final mat in roles)
                    DropdownMenuItem(value: mat, child: Text('$mat mat')),
                ],
                onChanged: (value) {
                  setState(() {
                    final assignments = widget.draft.putIfAbsent(
                      'mat_assignments',
                      () => <String, dynamic>{},
                    ) as Map;
                    assignments[role] = value;
                  });
                  widget.changed();
                },
              ),
            ],
          ),
        for (final role in roles)
          ArgoSection(
            title: '$role mat',
            children: [
              if (template != 'custom_checkerboards') ...[
                MeasuredField(
                  key: ValueKey('$role-distance'),
                  label:
                      'Distance from ${role == 'front' || role == 'rear' ? 'bumper' : 'body side'} to nearest inner-corner row (m)',
                  value: (mats[role] as Map?)?['setup_distance_m'],
                  changed: (v) => _guided(role, 'setup_distance_m', v),
                ),
                MeasuredField(
                  key: ValueKey('$role-offset'),
                  label: role == 'front' || role == 'rear'
                      ? 'Mat centre offset to vehicle left (m; enter 0 if centred)'
                      : 'Mat centre offset forward from vehicle body centre (m; enter 0 if centred)',
                  value: (mats[role] as Map?)?['setup_offset_m'],
                  changed: (v) => _guided(role, 'setup_offset_m', v),
                ),
                Text(
                  role == 'front'
                      ? 'First corner: left end of the nearest row. Number across to the right, then away from the vehicle.'
                      : role == 'rear'
                      ? 'First corner: right end of the nearest row. Number across to the left, then away from the vehicle.'
                      : role == 'left'
                      ? 'First corner: rear end of the nearest row. Number forward, then away from the vehicle.'
                      : 'First corner: front end of the nearest row. Number rearward, then away from the vehicle.',
                ),
              ],
              for (final field in const [
                ('columns', 'Inner corners per row'),
                ('rows', 'Inner corner rows'),
                ('square_m', 'Measured square side (m)'),
              ])
                MeasuredField(
                  key: ValueKey('$role-${field.$1}'),
                  label: field.$2,
                  value: _value(mats[role] as Map?, field.$1),
                  changed: (value) {
                    final mat = mats.putIfAbsent(
                      role,
                      () => <String, dynamic>{},
                    ) as Map<String, dynamic>;
                    if (field.$1 == 'x' || field.$1 == 'y') {
                      final origin = mat.putIfAbsent(
                        'origin_vehicle_m',
                        () => [null, null, 0.0],
                      ) as List;
                      origin[field.$1 == 'x' ? 0 : 1] = value;
                    } else {
                      mat[field.$1] =
                          (field.$1 == 'columns' || field.$1 == 'rows')
                          ? value?.toInt()
                          : value;
                    }
                    if (template != 'custom_checkerboards') _derive(role);
                    widget.changed();
                  },
                ),
              ExpansionTile(
                title: const Text('Advanced / Custom measured layout'),
                children: [
                  for (final field in const [
                    ('x', 'First inner corner X forward (m)'),
                    ('y', 'First inner corner Y left (m)'),
                    ('yaw_degrees', 'Row direction from +X (degrees)'),
                  ])
                    MeasuredField(
                      key: ValueKey(
                        '$role-advanced-${field.$1}-${_value(mats[role] as Map?, field.$1)}',
                      ),
                      label: field.$2,
                      value: _value(mats[role] as Map?, field.$1),
                      changed: (v) {
                        final mat = mats.putIfAbsent(
                          role,
                          () => <String, dynamic>{},
                        ) as Map;
                        if (field.$1 == 'yaw_degrees') {
                          mat[field.$1] = v;
                        } else {
                          final origin = mat.putIfAbsent(
                            'origin_vehicle_m',
                            () => [null, null, 0.0],
                          ) as List;
                          origin[field.$1 == 'x' ? 0 : 1] = v;
                        }
                        widget.changed();
                      },
                    ),
                ],
              ),
            ],
          ),
      ],
    );
  }

  void _guided(String role, String key, double? value) {
    final mats = widget.draft['mats'] as Map;
    final mat = mats.putIfAbsent(role, () => <String, dynamic>{}) as Map;
    mat[key] = value;
    _derive(role);
    widget.changed();
  }

  void _derive(String role) {
    final mat = (widget.draft['mats'] as Map)[role] as Map;
    final vehicle = widget.draft['vehicle'] as Map;
    try {
      final derived = MeasuredMatLayout.derive(
        role: role,
        length: (vehicle['length_m'] as num).toDouble(),
        rearOverhang: (vehicle['rear_overhang_m'] as num).toDouble(),
        bodyWidth: (vehicle['body_width_m'] as num).toDouble(),
        columns: (mat['columns'] as num).toInt(),
        square: (mat['square_m'] as num).toDouble(),
        distance: (mat['setup_distance_m'] as num).toDouble(),
        offset: (mat['setup_offset_m'] as num).toDouble(),
      );
      mat.addAll(derived);
    } on Object {
      mat.remove('origin_vehicle_m');
      mat.remove('yaw_degrees');
    }
  }

  Object? _value(Map? mat, String key) => key == 'x'
      ? mat?['origin_vehicle_m']?[0]
      : key == 'y'
      ? mat?['origin_vehicle_m']?[1]
      : mat?[key];
}
