import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:argo/core/projection/carplay_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dashboard viewport coalesces without persistent writes or reconnects', () async {
    final directory = await Directory.systemTemp.createTemp(
      'carplay-viewport-',
    );
    final path = '${directory.path}/settings';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final requests = <Map<String, dynamic>>[];
    final sockets = <Socket>[];
    Map<String, dynamic>? viewport;
    final subscription = server.listen((socket) async {
      sockets.add(socket);
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first;
      final request = jsonDecode(line) as Map<String, dynamic>;
      requests.add(request);
      if (request['action'] == 'viewport') {
        viewport = request['viewport'] as Map<String, dynamic>;
      }
      socket.writeln(
        jsonEncode(
          request['action'] == 'status'
              ? {
                  'ok': true,
                  'contract': 1,
                  'settings': {'width': 1280, 'height': 720},
                  'viewport_supported': true,
                  'viewport': viewport,
                }
              : {'ok': true},
        ),
      );
      await socket.flush();
      await socket.close();
    });
    final service = CarPlaySettingsService(socketPath: path);
    addTearDown(() async {
      await service.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
      await directory.delete(recursive: true);
    });
    service.setViewport(800, 498, 48);
    service.setViewport(600, 680, 64);
    await service.start();
    expect(viewport, {'width': 600.0, 'height': 680.0, 'overlay_height': 64.0});
    await service.refresh();
    expect(requests.where((r) => r['action'] == 'viewport'), hasLength(1));
    // A daemon restart loses runtime hints, and the next status restores them.
    viewport = null;
    await service.refresh();
    expect(requests.where((r) => r['action'] == 'viewport'), hasLength(2));
    service.setViewport(600, 680, 64);
    service.setViewport(double.nan, 680, 64);
    service.setViewport(600, 680, 680);
    await service.refresh();
    expect(service.measuredViewport, (600.0, 680.0, 64.0));
    expect(
      requests.every(
        (r) => r['action'] == 'status' || r['action'] == 'viewport',
      ),
      isTrue,
    );
  });

  test('closing cancels a viewport request and all later work', () async {
    final directory = await Directory.systemTemp.createTemp(
      'carplay-viewport-close-',
    );
    final path = '${directory.path}/settings';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final pending = Completer<void>();
    final sockets = <Socket>[];
    final subscription = server.listen((socket) async {
      sockets.add(socket);
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first;
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['action'] == 'viewport') {
        pending.complete();
      } else {
        socket.writeln(
          jsonEncode({
            'ok': true,
            'contract': 1,
            'settings': {},
            'viewport_supported': true,
          }),
        );
        await socket.flush();
        await socket.close();
      }
    });
    final service = CarPlaySettingsService(socketPath: path);
    addTearDown(() async {
      await service.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
      await directory.delete(recursive: true);
    });
    await service.start();
    service.setViewport(600, 680, 64);
    await pending.future.timeout(const Duration(seconds: 3));
    await service.close().timeout(const Duration(seconds: 3));
    await service.refresh();
    service.setViewport(800, 498, 48);
  });
}
