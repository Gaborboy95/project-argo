import 'package:flutter/material.dart';

class MeasuredField extends StatelessWidget {
  const MeasuredField({
    super.key,
    required this.label,
    required this.value,
    required this.changed,
  });
  final String label;
  final Object? value;
  final void Function(double?) changed;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextFormField(
      initialValue: value?.toString() ?? '',
      decoration: InputDecoration(labelText: label),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      onChanged: (text) {
        final n = double.tryParse(text);
        changed(n != null && n.isFinite ? n : null);
      },
    ),
  );
}

class LayoutDiagram extends StatelessWidget {
  const LayoutDiagram({super.key, required this.mats, required this.vehicle});
  final Map<String, dynamic> vehicle;
  final Map<String, dynamic> mats;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 240,
    child: CustomPaint(
      painter: _LayoutPainter(mats, vehicle),
      child: const Align(
        alignment: Alignment.bottomCenter,
        child: Text(
          'X forward ↑ • Y left ← • origin at rear axle\nMat origin = first inner corner; yaw turns rows from +X',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}

class _LayoutPainter extends CustomPainter {
  _LayoutPainter(this.mats, this.vehicle);
  final Map<String, dynamic> vehicle;
  final Map<String, dynamic> mats;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 20);
    final paint = Paint()..color = Colors.blueGrey;
    final length = vehicle['length_m'] as num?,
        rear = vehicle['rear_overhang_m'] as num?,
        width = vehicle['body_width_m'] as num?;
    if (length != null &&
        rear != null &&
        width != null &&
        length > rear &&
        rear > 0 &&
        width > 0) {
      canvas.drawRect(
        Rect.fromLTRB(
          center.dx - width * 11,
          center.dy - (length - rear) * 22,
          center.dx + width * 11,
          center.dy + rear * 22,
        ),
        paint,
      );
    }
    canvas.drawLine(
      center - const Offset(20, 0),
      center + const Offset(20, 0),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);
    for (final entry in mats.entries) {
      final m = entry.value as Map;
      final origin = m['origin_vehicle_m'] as List?;
      if (origin == null ||
          origin.length != 3 ||
          origin[0] is! num ||
          origin[1] is! num) {
        continue;
      }
      final p =
          center +
          Offset(
            -(origin[1] as num).toDouble() * 22,
            -(origin[0] as num).toDouble() * 22,
          );
      canvas.drawCircle(p, 7, Paint()..color = Colors.orange);
      final text = TextPainter(
        text: TextSpan(
          text: entry.key,
          style: const TextStyle(color: Colors.orange, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, p + const Offset(8, 0));
    }
  }

  @override
  bool shouldRepaint(covariant _LayoutPainter old) => true;
}
