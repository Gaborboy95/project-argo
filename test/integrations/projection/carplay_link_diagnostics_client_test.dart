import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:argo/core/projection/carplay_link_diagnostics.dart';
import 'package:argo/integrations/projection/carplay_link_diagnostics_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('health is typed and cannot claim a validated CarPlay session', () {
    final health = decodeCarPlayLinkHealth(jsonEncode(_healthy));
    expect(health.serviceAvailable, isTrue);
    expect(health.linkResolved, isTrue);
    expect(health.mfi, CarPlayMfiHealth.ready);
    expect(health.protocolMajor, 3);
    expect(health.wifiControlAvailable, isTrue);
    expect(health.accessPointEnabled, isFalse);
    for (final change in [
      {'contract': 2},
      {'implementation': 'native-carplay'},
      {'session_validated': true},
      {'bluetooth_bridge': 'ready'},
      {'protocol_major': 256},
      {'certificate_bytes': 4097},
      {'address': 'not-an-ipv4-address'},
      {'discovery': 'unavailable'},
      {
        'wifi_status': {'access_point_enabled': 'yes'},
      },
      {'mfi': 'emulated'},
    ]) {
      expect(
        () => decodeCarPlayLinkHealth(jsonEncode({..._healthy, ...change})),
        throwsFormatException,
      );
    }
    expect(() => decodeCarPlayLinkHealth(' ' * 4096), throwsFormatException);
    expect(() => decodeCarPlayLinkHealth('[]'), throwsFormatException);
  });

  test(
    'fragmented status request is read-only and concurrent refreshes coalesce',
    () async {
      final fixture = await _Server.start((socket) async {
        final response = '${jsonEncode(_healthy)}\n';
        socket.write(response.substring(0, 20));
        await socket.flush();
        socket.write(response.substring(20));
        await socket.flush();
      });
      addTearDown(fixture.close);
      final client = CarPlayLinkDiagnosticsClient(socketPath: fixture.path);
      addTearDown(client.close);
      final updates = <CarPlayLinkHealth>[];
      final subscription = client.changes.listen(updates.add);
      addTearDown(subscription.cancel);
      await Future.wait([client.refresh(), client.refresh(), client.refresh()]);
      expect(fixture.commands, ['status']);
      expect(updates, hasLength(1));
      expect(client.current.mfi, CarPlayMfiHealth.ready);
      await client.refresh();
      expect(fixture.commands, ['status', 'status']);
      expect(updates, hasLength(1));
    },
  );

  test(
    'malformed/truncated/oversized replies fail closed and reconnect recovers',
    () async {
      var response = 'bad JSON\n';
      final fixture = await _Server.start((socket) async {
        socket.write(response);
        await socket.flush();
        await socket.close();
      });
      addTearDown(fixture.close);
      final client = CarPlayLinkDiagnosticsClient(socketPath: fixture.path);
      addTearDown(client.close);
      for (final malformed in [
        'bad JSON\n',
        jsonEncode(
          _healthy,
        ), // Missing newline: truncated, even if JSON is valid.
        '${' ' * 4096}\n',
        '${jsonEncode(_healthy)}\nsecond response\n',
      ]) {
        response = malformed;
        await client.refresh();
        expect(client.current.serviceAvailable, isFalse);
        expect(client.current.mfi, CarPlayMfiHealth.unavailable);
      }
      response = '${jsonEncode(_healthy)}\n';
      await client.refresh();
      expect(client.current.serviceAvailable, isTrue);
      expect(client.current.mfi, CarPlayMfiHealth.ready);
    },
  );

  test(
    'whole-request deadline rejects a peer that never completes status',
    () async {
      final fixture = await _Server.start((_) async {});
      addTearDown(fixture.close);
      final client = CarPlayLinkDiagnosticsClient(
        socketPath: fixture.path,
        requestTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(client.close);
      await client.refresh();
      expect(client.current.serviceAvailable, isFalse);
      expect(client.current.error, contains('timed out'));
    },
  );

  test('unavailable service does not retain stale successful health', () async {
    final fixture = await _Server.start((socket) async {
      socket.write('${jsonEncode(_healthy)}\n');
      await socket.flush();
    });
    final client = CarPlayLinkDiagnosticsClient(socketPath: fixture.path);
    addTearDown(client.close);
    await client.refresh();
    expect(client.current.linkResolved, isTrue);
    await fixture.close();
    await client.refresh();
    expect(client.current.linkResolved, isFalse);
    expect(client.current.address, isNull);
    expect(client.current.mfi, CarPlayMfiHealth.unavailable);
  });

  test(
    'close cancels polling and in-flight status without late updates',
    () async {
      final request = Completer<void>();
      final fixture = await _Server.start((_) async {
        if (!request.isCompleted) request.complete();
      });
      addTearDown(fixture.close);
      final client = CarPlayLinkDiagnosticsClient(
        socketPath: fixture.path,
        pollInterval: const Duration(milliseconds: 10),
      );
      final updates = <CarPlayLinkHealth>[];
      client.changes.listen(updates.add);
      client.start();
      await request.future;
      await Future.wait([client.close(), client.close()]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fixture.commands, ['status']);
      expect(updates, isEmpty);
      await client.refresh();
      expect(fixture.commands, ['status']);
    },
  );
}

const _healthy = <String, Object?>{
  'contract': 1,
  'implementation': 'diagnostics-only',
  'session_validated': false,
  'discovery': 'resolved',
  'address': '192.0.2.20',
  'mfi': 'ready',
  'protocol_major': 3,
  'certificate_bytes': 128,
  'wifi': 'ready',
  'wifi_status': {
    'access_point_enabled': false,
    'bluetooth_enabled': true,
    'country': 'GB',
    'channel': 36,
  },
  'bluetooth_bridge': 'not-probed',
  'iap_handoff': 'not-probed',
  'error': null,
};

final class _Server {
  _Server(this.directory, this.server, this.path);
  static Future<_Server> start(Future<void> Function(Socket) respond) async {
    final directory = await Directory.systemTemp.createTemp('argo-health-');
    final path = '${directory.path}/health.sock';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final fixture = _Server(directory, server, path);
    server.listen((socket) {
      fixture.sockets.add(socket);
      final bytes = <int>[];
      socket.listen((data) async {
        bytes.addAll(data);
        if (bytes.contains(10)) {
          fixture.commands.add(utf8.decode(bytes).trimRight());
          bytes.clear();
          await respond(socket);
        }
      });
    });
    return fixture;
  }

  final Directory directory;
  final ServerSocket server;
  final String path;
  final sockets = <Socket>[];
  final commands = <String>[];
  bool closed = false;
  Future<void> close() async {
    if (closed) return;
    closed = true;
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
    await directory.delete(recursive: true);
  }
}
