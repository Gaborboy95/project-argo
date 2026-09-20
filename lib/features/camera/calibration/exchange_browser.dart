import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/camera/calibration_manager.dart';

/// Bounded, local JSON exchange. Engine schema validation remains authoritative.
class CalibrationExchange {
  static const maxBytes = 2 * 1024 * 1024;

  static Future<List<int>> readJson(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('Choose a regular JSON file');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('Calibration files must be at most 2 MiB');
      }
      bytes.addAll(chunk);
    }
    if (jsonDecode(utf8.decode(bytes)) is! Map) {
      throw const FormatException('Expected a calibration JSON object');
    }
    return bytes;
  }

  static Future<Map<String, dynamic>?> importFile(
    BuildContext context,
    CalibrationManager manager, {
    required bool lensProfile,
  }) async {
    final selected = await _choose(context, directory: false);
    if (selected == null) return null;
    final bytes = await readJson(File(selected));
    final data = jsonDecode(utf8.decode(bytes)) as Map;
    final isProfile =
        data['schema'] == 'surround-camera.lens-profile' ||
        (data['schema'] == null &&
            data.containsKey('K') &&
            data.containsKey('D'));
    if (isProfile != lensProfile) {
      throw FormatException(
        lensProfile
            ? 'Choose a lens profile, not a vehicle calibration'
            : 'Choose a vehicle calibration, not a lens profile',
      );
    }
    final exchange = await manager.call('exchange_list');
    final inbox = Directory(exchange['inbox'] as String);
    if (await FileSystemEntity.type(inbox.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('Import directory is unavailable');
    }
    final name =
        'argo-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}.json';
    final staged = File('${inbox.path}/$name');
    await staged.create(exclusive: true);
    try {
      await staged.writeAsBytes(bytes, flush: true);
      // Import creates a candidate/profile; it never activates it.
      return await manager.call('exchange_import', {'name': name});
    } finally {
      await staged.delete();
    }
  }

  static Future<bool> exportFile(
    BuildContext context,
    CalibrationManager manager, {
    required String kind,
    required String id,
  }) async {
    final directory = await _choose(context, directory: true);
    if (directory == null) return false;
    final result = await manager.call('exchange_export', {
      'kind': kind,
      'id': id,
    });
    final name = result['name'] as String;
    if (name.contains('/') || name.contains('\\') || !name.endsWith('.json')) {
      throw const FormatException('Invalid export filename');
    }
    final bytes = await readJson(File('${result['directory']}/$name'));
    final target = File('$directory/$name');
    // Never replace an existing user file, including a link.
    await target.create(exclusive: true);
    try {
      await target.writeAsBytes(bytes, flush: true);
    } catch (_) {
      await target.delete();
      rethrow;
    }
    return true;
  }

  static Future<String?> _choose(
    BuildContext context, {
    required bool directory,
  }) {
    final home = Platform.environment['HOME'];
    if (home == null) {
      throw const FileSystemException('User home is unavailable');
    }
    return showDialog<String>(
      context: context,
      builder: (_) => _ExchangeBrowser(root: home, directory: directory),
    );
  }
}

class _ExchangeBrowser extends StatefulWidget {
  const _ExchangeBrowser({required this.root, required this.directory});
  final String root;
  final bool directory;
  @override
  State<_ExchangeBrowser> createState() => _ExchangeBrowserState();
}

class _ExchangeBrowserState extends State<_ExchangeBrowser> {
  late String _path = widget.root;
  List<FileSystemEntity> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final root = await Directory(widget.root).resolveSymbolicLinks();
      final resolved = await Directory(path).resolveSymbolicLinks();
      if (resolved != root && !resolved.startsWith('$root/')) {
        throw const FileSystemException('Choose a folder within your home');
      }
      final entries = <FileSystemEntity>[];
      var count = 0;
      await for (final item in Directory(resolved).list(followLinks: false)) {
        if (++count > 2048) {
          throw const FileSystemException(
            'Too many entries; choose a smaller folder',
          );
        }
        final name = item.path.split('/').last;
        if (name.startsWith('.') || item is Link) continue;
        if (item is Directory ||
            (!widget.directory && name.endsWith('.json'))) {
          entries.add(item);
        }
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      if (!mounted) return;
      setState(() {
        _path = resolved;
        _entries = entries;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.directory ? 'Export to folder' : 'Import JSON file'),
    content: SizedBox(
      width: 540,
      height: 400,
      child: Column(
        children: [
          Text(_path == widget.root ? 'Home' : _path.split('/').last),
          const Text('Browse folders in your home. JSON files up to 2 MiB.'),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          if (_path != widget.root)
            TextButton(
              onPressed: _loading
                  ? null
                  : () => _load(Directory(_path).parent.path),
              child: const Text('Parent folder'),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (_, index) {
                final entry = _entries[index];
                return ListTile(
                  leading: Icon(
                    entry is Directory ? Icons.folder : Icons.description,
                  ),
                  title: Text(entry.path.split('/').last),
                  onTap: _loading
                      ? null
                      : () {
                          if (entry is Directory) {
                            _load(entry.path);
                          } else {
                            Navigator.pop(context, entry.path);
                          }
                        },
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      if (widget.directory)
        FilledButton(
          onPressed: _loading || _error != null
              ? null
              : () => Navigator.pop(context, _path),
          child: const Text('Export here'),
        ),
    ],
  );
}
