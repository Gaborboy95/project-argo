import 'package:argo/core/vehicle/vehicle_signals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('engine RPM normalizes integers and doubles', () {
    expect(VehicleSignals.engineRpm.decode(3000), 3000.0);
    expect(VehicleSignals.engineRpm.decode(2875.5), 2875.5);
  });

  test('engine RPM rejects non-numeric values', () {
    expect(
      () => VehicleSignals.engineRpm.decode('3000'),
      throwsFormatException,
    );
  });
}
