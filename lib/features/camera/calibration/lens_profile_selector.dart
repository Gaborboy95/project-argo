import 'package:flutter/material.dart';

import '../../../core/camera/calibration_manager.dart';
import 'exchange_browser.dart';
import '../../shared/argo_components.dart';

class LensProfileSelector extends StatefulWidget {
  const LensProfileSelector({
    super.key,
    required this.manager,
    required this.cameras,
    required this.applied,
    required this.bench,
  });
  final CalibrationManager manager;
  final Map<String, dynamic> cameras;
  final void Function(Map<String, dynamic>) applied;
  final VoidCallback bench;
  @override
  State<LensProfileSelector> createState() => _LensProfileSelectorState();
}

class _LensProfileSelectorState extends State<LensProfileSelector> {
  List<Map> _profiles = [];
  String? _selected, _message;
  final Set<String> _checked = {};
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _checked.addAll(widget.cameras.keys);
    _run(_refresh);
  }

  Future<void> _refresh() async {
    final s = await widget.manager.call('profile_list');
    _profiles = (s['profiles'] as List).cast<Map>();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _message = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<String?> _name(String title) async {
    final c = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    c.dispose();
    return result;
  }

  Future<void> _import() async {
    final result = await CalibrationExchange.importFile(
      context,
      widget.manager,
      lensProfile: true,
    );
    if (result != null) {
      await _refresh();
      _message = 'Lens profile imported. Select matching cameras to apply it.';
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'A shared lens profile assumes equivalent optics and identical resolution, orientation and crop. Individual camera tolerances still require inspection.',
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null) Text(_message!),
      for (final p in _profiles)
        ListTile(
          selected: _selected == p['id'],
          leading: Icon(
            _selected == p['id']
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
          ),
          onTap: () => setState(() => _selected = p['id'] as String),
          title: Text('${p['display_name']} • ${p['image_size']}'),
          subtitle: Text(
            '${p['lens_model']} • RMS ${p['diagnostics']?['rms_px'] ?? 'unknown'} px\n${p['source']}\nCalibrated ${DateTime.fromMillisecondsSinceEpoch(((p['calibrated_ns'] as num) / 1000000).round())}',
          ),
        ),
      for (final e in widget.cameras.entries)
        CheckboxListTile(
          value: _checked.contains(e.key),
          onChanged: (v) => setState(
            () => v == true ? _checked.add(e.key) : _checked.remove(e.key),
          ),
          title: Text('${e.value['role']} • ${e.key}'),
        ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: _selected == null || _busy
                ? null
                : () => _run(() async {
                    final result = await widget.manager.call('profile_apply', {
                      'id': _selected,
                      'cameras': {
                        for (final id in _checked) id: widget.cameras[id],
                      },
                    });
                    widget.applied(
                      Map<String, dynamic>.from(result['cameras'] as Map),
                    );
                  }),
            child: const Text('Use profile for selected matching cameras'),
          ),
          TextButton(
            onPressed: widget.bench,
            child: const Text('Calibrate new profile'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _run(_import),
            child: const Text('Import lens profile'),
          ),
          if (_selected != null) ...[
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final saved = await CalibrationExchange.exportFile(
                        context,
                        widget.manager,
                        kind: 'profile',
                        id: _selected!,
                      );
                      if (saved) {
                        _message =
                            'Lens profile exported to the selected folder';
                      }
                    }),
              child: const Text('Export lens profile'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final n = await _name('Duplicate profile');
                      if (n != null) {
                        await widget.manager.call('profile_duplicate', {
                          'id': _selected,
                          'name': n,
                        });
                        await _refresh();
                      }
                    }),
              child: const Text('Duplicate'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final n = await _name('Rename profile');
                      if (n != null) {
                        await widget.manager.call('profile_rename', {
                          'id': _selected,
                          'name': n,
                        });
                        await _refresh();
                      }
                    }),
              child: const Text('Rename'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      if (!await confirmArgoAction(
                        context,
                        title: 'Delete lens profile?',
                        explanation: 'Only an unused profile can be deleted. Profiles referenced by saved calibrations are retained.',
                        action: 'Delete profile',
                      )) {
                        return;
                      }
                      await widget.manager.call('profile_delete', {
                        'id': _selected,
                      });
                      _selected = null;
                      await _refresh();
                    }),
              child: const Text('Delete unused'),
            ),
          ],
          TextButton(
            onPressed: _busy ? null : () => _run(_refresh),
            child: const Text('Refresh profiles'),
          ),
        ],
      ),
    ],
  );
}
