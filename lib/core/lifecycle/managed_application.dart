import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../connectivity/connectivity_service.dart';
import 'application_exit_service.dart';

/// Private same-account administration; never acquires another projection lease.
final class ManagedApplication {
  ManagedApplication(this.environment, this.connectivity);
  final Map<String, String> environment;
  final ConnectivityService? connectivity;
  ServerSocket? _server;
  final Set<Socket> _clients = {};
  bool _stopTarget = true;
  bool _quitting = false;
  bool rendered = false;

  Future<void> start(ApplicationExitService exitService) async {
    final path = environment['ARGO_MANAGED_SOCKET'];
    if (path == null) return;
    // The launcher owns this private runtime directory and refuses a second app.
    final socketFile = File(path);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      socketFile.deleteSync();
    }
    _server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    _server!.listen((client) {
      if (_clients.length >= 4) {
        client.destroy();
        return;
      }
      _clients.add(client);
      unawaited(_handle(client, exitService));
    });
  }

  Future<void> _handle(
    Socket client,
    ApplicationExitService exitService,
  ) async {
    var ownsQuit = false;
    try {
      // One bounded request per socket, with no identity/media payloads.
      final buffer = <int>[];
      await for (final bytes in client.timeout(const Duration(seconds: 2))) {
        buffer.addAll(bytes);
        if (buffer.length > 32) throw const FormatException('Request too long');
        if (!buffer.contains(10)) continue;
        final command = utf8.decode(buffer).trim();
        if (command == 'status') {
          client.writeln(
            jsonEncode({
              'ready':
                  rendered &&
                  !_quitting &&
                  (connectivity?.connectivity.daemonConnected ?? false),
              'invocation': environment['INVOCATION_ID'],
            }),
          );
        } else if (command == 'quit' || command == 'quit-target') {
          if (!_quitting) {
            ownsQuit = true;
            // A service stop already owns its target job; UI/CLI Quit does not.
            _stopTarget = command == 'quit-target';
            _quitting = true;
          }
          await exitService.quit();
        } else {
          throw const FormatException('Expected status or quit');
        }
        break;
      }
      await client.flush();
    } on Object catch (error) {
      if (ownsQuit) {
        _quitting = false;
        _stopTarget = true;
      }
      try {
        client.writeln(jsonEncode({'error': error.toString()}));
        await client.flush();
      } on Object {
        // Caller disappearance must not cancel owned cleanup.
      }
    } finally {
      _clients.remove(client);
      client.destroy();
    }
  }

  /// Called only after acknowledged daemon cleanup and application shutdown.
  Future<void> completed() async {
    final marker = environment['ARGO_MANAGED_RESULT'];
    if (marker == null) return;
    final temporary = File('$marker.new');
    await temporary.writeAsString(
      jsonEncode({
        'result': 'clean',
        'invocation': environment['INVOCATION_ID'],
        'release': environment['ARGO_WIRELESS_BUNDLE'],
      }),
      flush: true,
    );
    await temporary.rename(marker);
    if (_stopTarget) {
      final result = await Process.run('systemctl', [
        '--user',
        '--no-block',
        'stop',
        'argo.target',
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) {
        throw StateError(
          'Could not stop argo.target after Quit: ${result.stderr}',
        );
      }
    }
  }

  Future<void> close() async {
    await _server?.close();
    // Keep the active Quit request open until cleanup completion/exit.
  }
}
