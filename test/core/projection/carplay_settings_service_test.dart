import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:argo/core/projection/carplay_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown microphone inventory preserves preferences, known absence clears once and replug restores', () async {
    final receiver = await _Receiver.start({
      'audio_sink': 'jbl.present',
      'audio_source': 'old.usb.adc',
    });
    String? microphone;
    final service = CarPlaySettingsService(
      socketPath: receiver.path,
      selectedAudioOutput: () => 'jbl.present',
      selectedMicrophone: () => microphone,
    );
    addTearDown(() async {
      await service.close();
      await receiver.close();
    });
    await service.start();
    expect(receiver.configures, isEmpty);
    expect(receiver.settings['audio_source'], 'old.usb.adc');
    microphone = '';
    await service.refresh();
    expect(receiver.configures.single['settings'], {'audio_source': null});
    expect(receiver.settings['audio_source'], isNull);
    expect((service.current['settings'] as Map)['audio_source'], isNull);
    await Future.wait([service.refresh(), service.refresh()]);
    expect(receiver.configures, hasLength(1));
    microphone = null;
    await service.refresh();
    expect(receiver.configures, hasLength(1));
    microphone = 'usb.adc';
    await service.refresh();
    expect(receiver.configures.last['settings'], {'audio_source': 'usb.adc'});
    expect(receiver.settings['audio_source'], 'usb.adc');
    await service.refresh();
    expect(receiver.configures, hasLength(2));
    expect(
      receiver.requests.every(
        (r) => {'status', 'configure'}.contains(r['action']),
      ),
      isTrue,
    );
  });

  test('connect awaits confirmed microphone absence before advertising the next session', () async {
    final receiver = await _Receiver.start({
      'audio_sink': 'jbl.present',
      'audio_source': 'old.usb.adc',
    });
    String? microphone;
    final service = CarPlaySettingsService(
      socketPath: receiver.path,
      selectedAudioOutput: () => 'jbl.present',
      selectedMicrophone: () => microphone,
    );
    addTearDown(() async {
      await service.close();
      await receiver.close();
    });
    await service.start();
    receiver.configureGate = Completer<void>();
    microphone = '';
    final connecting = service.connect();
    await receiver.configureSeen.future.timeout(const Duration(seconds: 2));
    expect(receiver.connectSinks, isEmpty);
    receiver.configureGate!.complete();
    await connecting;
    expect(receiver.connectSinks, ['jbl.present']);
    expect(receiver.connectSources, [null]);
    expect(receiver.configures.single['settings'], {'audio_source': null});
    expect(service.failure, isNull);
  });

  test('shared output and microphone update next-connection settings without receiver actions', () async {
    final receiver = await _Receiver.start({
      'audio_sink': 'old.missing',
      'audio_source': 'old.microphone',
    });
    String? output = 'jbl.present';
    final service = CarPlaySettingsService(
      socketPath: receiver.path,
      selectedAudioOutput: () => output,
      selectedMicrophone: () => 'shared.microphone',
    );
    addTearDown(() async {
      await service.close();
      await receiver.close();
    });
    await service.start();
    expect(receiver.settings['audio_sink'], 'jbl.present');
    expect(receiver.settings['audio_source'], 'shared.microphone');
    expect(receiver.configures.single['settings'], {
      'audio_sink': 'jbl.present',
      'audio_source': 'shared.microphone',
    });
    expect((service.current['settings'] as Map)['audio_sink'], 'jbl.present');
    final statusCount = receiver.requests
        .where((r) => r['action'] == 'status')
        .length;
    await Future.wait([
      service.refresh(),
      service.refresh(),
      service.refresh(),
    ]);
    expect(
      receiver.requests.where((r) => r['action'] == 'status').length,
      statusCount + 1,
    );
    expect(receiver.configures, hasLength(1));
    output = 'usb.present';
    await service.refresh();
    expect(receiver.configures.last['settings'], {'audio_sink': 'usb.present'});
    expect(receiver.settings['audio_sink'], 'usb.present');
    receiver.settings['audio_sink'] = 'old.after.restart';
    await service.refresh();
    expect(receiver.configures, hasLength(3));
    expect(receiver.settings['audio_sink'], 'usb.present');
    expect(
      receiver.requests.every(
        (r) => {'status', 'configure'}.contains(r['action']),
      ),
      isTrue,
    );
    expect(service.failure, isNull);
  });

  test('missing or unset shared output never overwrites a native choice or invents a fallback', () async {
    final receiver = await _Receiver.start({
      'audio_sink': 'saved.missing',
      'audio_source': null,
    });
    String? output;
    String? microphone;
    final service = CarPlaySettingsService(
      socketPath: receiver.path,
      selectedAudioOutput: () => output,
      selectedMicrophone: () => microphone,
    );
    addTearDown(() async {
      await service.close();
      await receiver.close();
    });
    await service.start();
    output = '';
    await service.refresh();
    expect(receiver.configures, isEmpty);
    expect(receiver.settings['audio_sink'], 'saved.missing');
    receiver.settings['audio_sink'] = null;
    output = null;
    microphone = 'shared.microphone';
    await service.refresh();
    expect(receiver.configures, isEmpty);
    expect(receiver.settings['audio_sink'], isNull);
    output = 'jbl.present';
    await service.refresh();
    expect(receiver.configures.single['settings'], {
      'audio_sink': 'jbl.present',
      'audio_source': 'shared.microphone',
    });
    expect(
      receiver.requests.where(
        (r) => r['action'] == 'connect' || r['action'] == 'disconnect',
      ),
      isEmpty,
    );
  });

  test('connect waits for the latest shared output acknowledgement before starting the phone', () async {
    final receiver = await _Receiver.start({'audio_sink': 'stale.output'});
    String? output;
    final service = CarPlaySettingsService(
      socketPath: receiver.path,
      selectedAudioOutput: () => output,
    );
    addTearDown(() async {
      await service.close();
      await receiver.close();
    });
    await service.start();
    receiver.configureGate = Completer<void>();
    output = 'first.present';
    final connecting = service.connectDevice('02:00:00:00:00:01');
    await receiver.configureSeen.future.timeout(const Duration(seconds: 2));
    expect(receiver.requests.where((r) => r['action'] == 'connect'), isEmpty);
    expect(service.saving, isTrue);
    output = 'latest.present';
    final polling = service.refresh();
    receiver.configureGate!.complete();
    await connecting;
    await polling;
    expect(receiver.connectSinks, ['latest.present']);
    expect(receiver.configures, hasLength(2));
    expect(
      receiver.requests.singleWhere((r) => r['action'] == 'connect')['target'],
      '02:00:00:00:00:01',
    );
    expect(service.failure, isNull);
  });

  test('a rejected shared-output update prevents connect and does not use a default sink', () async {
    final receiver = await _Receiver.start({'audio_sink': 'saved.stale'});
    String? output;
    final service = CarPlaySettingsService(
      socketPath: receiver.path,
      selectedAudioOutput: () => output,
    );
    addTearDown(() async {
      await service.close();
      await receiver.close();
    });
    await service.start();
    output = 'chosen.present';
    receiver.rejectConfigure = true;
    await service.connect();
    expect(service.failure, isNotNull);
    expect(receiver.connectSinks, isEmpty);
    expect(receiver.settings['audio_sink'], 'saved.stale');
    receiver.rejectConfigure = false;
    await service.refresh();
    expect(service.failure, isNull);
    expect(receiver.settings['audio_sink'], 'chosen.present');
    expect(receiver.connectSinks, isEmpty);
  });

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

class _Receiver {
  _Receiver(this.directory, this.server, this.settings);
  final Directory directory;
  final ServerSocket server;
  final Map<String, dynamic> settings;
  final requests = <Map<String, dynamic>>[];
  final connectSinks = <Object?>[];
  final connectSources = <Object?>[];
  final sockets = <Socket>{};
  final work = <Future<void>>{};
  final configureSeen = Completer<void>();
  Completer<void>? configureGate;
  bool rejectConfigure = false;
  late final StreamSubscription<Socket> subscription;
  String get path => '${directory.path}/settings';
  List<Map<String, dynamic>> get configures =>
      requests.where((r) => r['action'] == 'configure').toList();
  static Future<_Receiver> start(Map<String, dynamic> settings) async {
    final directory = await Directory.systemTemp.createTemp(
      'carplay-shared-audio-',
    );
    final server = await ServerSocket.bind(
      InternetAddress(
        '${directory.path}/settings',
        type: InternetAddressType.unix,
      ),
      0,
    );
    final receiver = _Receiver(directory, server, settings);
    receiver.subscription = server.listen((socket) {
      receiver.sockets.add(socket);
      final task = receiver.handle(socket);
      receiver.work.add(task);
      task.whenComplete(() => receiver.work.remove(task));
    });
    return receiver;
  }

  Future<void> handle(Socket socket) async {
    try {
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first;
      final request = jsonDecode(line) as Map<String, dynamic>;
      requests.add(request);
      var ok = true;
      switch (request['action']) {
        case 'configure':
          if (!configureSeen.isCompleted) configureSeen.complete();
          await configureGate?.future;
          ok = !rejectConfigure;
          if (ok) {
            settings.addAll(
              Map<String, dynamic>.from(request['settings'] as Map),
            );
          }
        case 'connect':
          connectSinks.add(settings['audio_sink']);
          connectSources.add(settings['audio_source']);
      }
      socket.writeln(
        jsonEncode(
          request['action'] == 'status'
              ? {
                  'ok': true,
                  'contract': 1,
                  'settings': {...settings},
                  'running': false,
                  'phase': 'Disconnected',
                }
              : {'ok': ok, if (!ok) 'error': 'Selected output rejected'},
        ),
      );
      await socket.flush();
      await socket.close();
    } on Object {
      // Closing the fixture cancels outstanding local requests.
    } finally {
      sockets.remove(socket);
      socket.destroy();
    }
  }

  Future<void> close() async {
    if (configureGate != null && !configureGate!.isCompleted) {
      configureGate!.complete();
    }
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await subscription.cancel();
    await server.close();
    await Future.wait(work.toList());
    await directory.delete(recursive: true);
  }
}
