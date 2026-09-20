import 'package:argo/core/camera/measured_mat_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object> layout(String role) => MeasuredMatLayout.derive(
    role: role,
    length: 4.5,
    rearOverhang: .9,
    bodyWidth: 1.8,
    columns: 5,
    square: .1,
    distance: .5,
    offset: 0,
  );
  test(
    'physical distances derive labelled first corners and outward row axes',
    () {
      expect(layout('front')['origin_vehicle_m'], [4.1, .2, 0]);
      expect(layout('front')['yaw_degrees'], -90);
      expect(layout('rear')['origin_vehicle_m'], [-1.4, -.2, 0]);
      expect(layout('rear')['yaw_degrees'], 90);
      expect((layout('left')['origin_vehicle_m'] as List)[1], 1.4);
      expect((layout('right')['origin_vehicle_m'] as List)[1], -1.4);
    },
  );
  test('invalid dimensions do not produce guessed anchors', () {
    expect(
      () => MeasuredMatLayout.derive(
        role: 'rear',
        length: 4.5,
        rearOverhang: .9,
        bodyWidth: 1.8,
        columns: 5,
        square: .1,
        distance: -1,
        offset: 0,
      ),
      throwsFormatException,
    );
  });
}
