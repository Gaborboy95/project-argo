/// Converts a deliberately placed board into the engine's rear-axle coordinates.
/// Distances refer to the nearest INNER-CORNER row, not the edge of the cloth.
abstract final class MeasuredMatLayout {
  static Map<String, Object> derive({
    required String role,
    required double length,
    required double rearOverhang,
    required double bodyWidth,
    required int columns,
    required double square,
    required double distance,
    required double offset,
  }) {
    if (![
          length,
          rearOverhang,
          bodyWidth,
          square,
          distance,
          offset,
        ].every((n) => n.isFinite) ||
        length <= 0 ||
        rearOverhang < 0 ||
        rearOverhang >= length ||
        bodyWidth <= 0 ||
        columns < 3 ||
        columns > 30 ||
        square < .001 ||
        square > 2 ||
        distance < 0) {
      throw const FormatException(
        'Enter valid measured vehicle and mat dimensions',
      );
    }
    final halfSpan = (columns - 1) * square / 2;
    final centreX = length / 2 - rearOverhang;
    final (x, y, yaw) = switch (role) {
      'front' => (length - rearOverhang + distance, offset + halfSpan, -90.0),
      'rear' => (-rearOverhang - distance, offset - halfSpan, 90.0),
      'left' => (centreX + offset - halfSpan, bodyWidth / 2 + distance, 0.0),
      'right' => (
        centreX + offset + halfSpan,
        -bodyWidth / 2 - distance,
        180.0,
      ),
      _ => throw const FormatException('Choose a measured mat role'),
    };
    return {
      'origin_vehicle_m': [x, y, 0.0],
      'yaw_degrees': yaw,
    };
  }
}
