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
          'Enter your cloth dimensions. Count INNER corners, not black squares. Measure the first inner corner from the rear axle ground centre. Y is positive to the left. Lay every mat flat on the same ground plane.',
        ),
        LayoutDiagram(
          mats: mats,
          vehicle: Map<String, dynamic>.from(widget.draft['vehicle'] as Map),
        ),
        for (final role in const ['front', 'rear', 'left', 'right'])
          Row(
            children: [
              Text('$role camera sees: '),
              DropdownButton<String>(
                value:
                    (widget.draft['mat_assignments'] as Map?)?[role]
                        as String? ??
                    role,
                items: [
                  for (final mat in const ['front', 'rear', 'left', 'right'])
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
        for (final role in const ['front', 'rear', 'left', 'right'])
          ExpansionTile(
            title: Text('$role mat'),
            children: [
              for (final field in const [
                ('columns', 'Inner corners per row'),
                ('rows', 'Inner corner rows'),
                ('square_m', 'Measured square side (m)'),
                ('x', 'First inner corner X forward (m)'),
                ('y', 'First inner corner Y left (m)'),
                ('yaw_degrees', 'Row direction from +X (degrees)'),
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
                    widget.changed();
                  },
                ),
            ],
          ),
      ],
    );
  }

  Object? _value(Map? mat, String key) => key == 'x'
      ? mat?['origin_vehicle_m']?[0]
      : key == 'y'
      ? mat?['origin_vehicle_m']?[1]
      : mat?[key];
}
