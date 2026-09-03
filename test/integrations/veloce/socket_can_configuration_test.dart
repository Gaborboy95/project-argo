import 'package:argo/integrations/veloce/socket_can_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SocketCAN stays disabled unless explicitly selected', () {
    expect(SocketCanConfiguration.fromEnvironment(const {}), isNull);
    expect(
      SocketCanConfiguration.fromEnvironment(const {
        'VELOCE_CAN_INPUT': 'auto',
      }),
      isNull,
    );
  });

  test('SocketCAN defaults to can0, comfort, and disabled writes', () {
    final configuration = SocketCanConfiguration.fromEnvironment(const {
      'VELOCE_CAN_INPUT': 'socketcan',
    });

    expect(configuration, isNotNull);
    expect(configuration!.interfaceName, 'can0');
    expect(configuration.logicalBus, 'comfort');
    expect(configuration.writesEnabled, isFalse);
  });

  test('SocketCAN reads explicit environment settings', () {
    final configuration = SocketCanConfiguration.fromEnvironment(const {
      'VELOCE_CAN_INPUT': 'SOCKETCAN',
      'VELOCE_SOCKETCAN_INTERFACE': 'vcan0',
      'VELOCE_CAN_BUS': 'comfort',
      'VELOCE_CAN_WRITE_ENABLED': 'true',
    });

    expect(configuration, isNotNull);
    expect(configuration!.interfaceName, 'vcan0');
    expect(configuration.logicalBus, 'comfort');
    expect(configuration.writesEnabled, isTrue);
  });

  test('SocketCAN rejects an invalid write toggle', () {
    expect(
      () => SocketCanConfiguration.fromEnvironment(const {
        'VELOCE_CAN_INPUT': 'socketcan',
        'VELOCE_CAN_WRITE_ENABLED': 'sometimes',
      }),
      throwsArgumentError,
    );
  });
}
