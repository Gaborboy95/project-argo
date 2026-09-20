import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/camera/camera_service.dart';
import '../../core/camera/surround_jobs.dart';
import 'ihs_camera_surface.dart';

class CameraRecordingsPage extends StatefulWidget {
  const CameraRecordingsPage({
    super.key,
    required this.service,
    required this.control,
  });
  final CameraService service;
  final SurroundCameraControl control;
  @override
  State<CameraRecordingsPage> createState() => _CameraRecordingsPageState();
}

class _CameraRecordingsPageState extends State<CameraRecordingsPage> {
  final _destination = TextEditingController(),
      _export = TextEditingController();
  final _quota = TextEditingController(text: '10');
  final _selected = <String>{};
  List<Map<String, dynamic>> _sessions = [];
  Map<String, dynamic> _status = {};
  Map<String, dynamic>? _session;
  String? _camera, _error;
  String _view = 'direct', _exportPolicy = 'passthrough';
  String _encodingPolicy = 'passthrough';
  int _quality = 60, _recordingFps = 10;
  bool _busy = false, _playing = false;
  int _position = 0;
  double _speed = 1;
  Timer? _timer;
  Stopwatch _clock = Stopwatch();
  int _lastTick = 0;
  Future<Map<String, dynamic>> request(Map<String, Object?> args) =>
      widget.control.command('recording', args, true);
  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.service.current.assignments.values);
    unawaited(
      run(() async {
        _status = await request({'action': 'status'});
      }),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _destination.dispose();
    _export.dispose();
    _quota.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on Object catch (error) {
      _error = '$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> browse() async {
    final data = await request({
      'action': 'list',
      'destination': _destination.text,
    });
    _sessions = (data['sessions'] as List? ?? [])
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList();
  }

  Future<void> render() async {
    final session = _session;
    if (session == null) return;
    final ids = _camera == null
        ? List<String>.from(session['cameras'] as List)
        : [_camera!];
    final result = await SurroundJob(widget.control).run('recording', {
      'action': 'replay',
      'session': session['session'],
      'position_ns': _position,
      'camera_ids': ids,
      'view': _view,
      'speed': _speed,
      'paused': !_playing,
      'output': '${session['session']}/argo-playback.png',
      'width': widget.service.current.width ?? 640,
      'height': widget.service.current.height ?? 480,
    });
    await widget.control.command('present', {
      'path': result['output'],
      'timeline': 'replay',
      'width': result['width'],
      'height': result['height'],
    });
  }

  void play(bool value) {
    _timer?.cancel();
    setState(() => _playing = value);
    _clock = Stopwatch()..start();
    _lastTick = 0;
    if (value) {
      _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        if (_busy || !mounted) return;
        final elapsed = _clock.elapsedMicroseconds * 1000;
        final delta = elapsed - _lastTick;
        _lastTick = elapsed;
        final end = _session?['end_ns'] as int? ?? _position;
        _position = (_position + (delta * _speed).round()).clamp(0, end);
        if (_position >= end) play(false);
        unawaited(run(render));
      });
    }
  }

  Widget button(String text, Future<void> Function() work) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 8),
    child: FilledButton.tonal(
      onPressed: _busy ? null : () => run(work),
      child: Text(text),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Camera recordings')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_busy) const LinearProgressIndicator(),
        const Text(
          'Separate camera tracks continue when Camera or Argo closes. Choose an existing private recording destination; removed storage is reported as a recording failure.',
        ),
        TextField(
          controller: _destination,
          decoration: const InputDecoration(
            labelText: 'Recording destination (absolute path)',
          ),
        ),
        TextField(
          controller: _quota,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Loop quota (GiB)'),
        ),
        DropdownButtonFormField<String>(
          initialValue: _encodingPolicy,
          decoration: const InputDecoration(labelText: 'Recording encoding'),
          items: const [
            DropdownMenuItem(
              value: 'passthrough',
              child: Text('Original encoded packets'),
            ),
            DropdownMenuItem(value: 'mjpeg', child: Text('Budgeted MJPEG')),
          ],
          onChanged: _busy
              ? null
              : (value) => setState(() => _encodingPolicy = value!),
        ),
        if (_encodingPolicy == 'mjpeg') ...[
          const Text(
            'Recompress separate camera tracks for lower storage use. Resolution stays unchanged; quality and frame-rate limits apply only to recording.',
          ),
          Text('JPEG quality $_quality'),
          Slider(
            value: _quality.toDouble(),
            min: 30,
            max: 90,
            divisions: 60,
            onChanged: _busy
                ? null
                : (value) => setState(() => _quality = value.round()),
          ),
          Text('Maximum $_recordingFps recording frames/s per camera'),
          Slider(
            value: _recordingFps.toDouble(),
            min: 1,
            max: 15,
            divisions: 14,
            onChanged: _busy
                ? null
                : (value) => setState(() => _recordingFps = value.round()),
          ),
        ],
        for (final camera in widget.service.current.devices)
          CheckboxListTile(
            value: _selected.contains(camera.stableId),
            title: Text(camera.displayName),
            subtitle: Text(camera.stableId),
            onChanged: _busy
                ? null
                : (selected) => setState(() {
                    if (selected!) {
                      _selected.add(camera.stableId);
                    } else {
                      _selected.remove(camera.stableId);
                    }
                  }),
          ),
        Wrap(
          children: [
            button('Start recording', () async {
              final quota = double.tryParse(_quota.text);
              if (quota == null || !quota.isFinite || quota <= 0) {
                throw const FormatException('Enter a positive disk quota');
              }
              _status = await request({
                'action': 'start',
                'destination': _destination.text,
                'camera_ids': _selected.toList(),
                'quota_bytes': (quota * 1024 * 1024 * 1024).round(),
                'encoding_policy': _encodingPolicy == 'passthrough'
                    ? {'mode': 'passthrough'}
                    : {
                        'mode': 'mjpeg',
                        'quality': _quality,
                        'max_fps_per_camera': _recordingFps,
                        'threads': 1,
                        'max_pixels_per_second': 80000000,
                        'queue_bytes': 33554432,
                        'timeout_ms': 750,
                      },
              });
            }),
            button('Stop recording', () async {
              _status = await request({'action': 'stop'});
            }),
            button('Protect event clip', () async {
              final event = await request({
                'action': 'event',
                'kind': 'manual',
                'pre_ns': 10000000000,
                'post_ns': 20000000000,
              });
              _status = {..._status, 'event': event};
            }),
            button('Refresh status', () async {
              _status = await request({'action': 'status'});
            }),
            button('Browse sessions', browse),
          ],
        ),
        Text(
          'Recorder: ${_status['state'] ?? 'unknown'} • drops ${_status['dropped'] ?? 'unknown'}\n${_status['error'] ?? _status['health'] ?? ''}',
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (final session in _sessions)
          ListTile(
            title: Text('${session['session']}'),
            subtitle: Text(
              '${session['state']} • ${(session['cameras'] as List).length} tracks • ${session['events']} events',
            ),
            selected: _session == session,
            onTap: _busy
                ? null
                : () => run(() async {
                    play(false);
                    _session = session;
                    _camera = null;
                    _position = session['start_ns'] as int;
                    await render();
                  }),
          ),
        if (_session != null) ...[
          const Divider(),
          const Text(
            'Recorded playback • recorded calibration • isolated from live vehicle signals',
          ),
          SizedBox(
            height: 280,
            child: AspectRatio(
              aspectRatio:
                  (widget.service.current.width ?? 640) /
                  (widget.service.current.height ?? 480),
              child: const IgnorePointer(
                child: IhsCameraSurface(
                  external: true,
                  key: ValueKey('camera-replay-view'),
                ),
              ),
            ),
          ),
          DropdownButton<String>(
            value: _camera ?? '',
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('All recorded cameras'),
              ),
              for (final id in _session!['cameras'] as List)
                DropdownMenuItem(value: '$id', child: Text('$id')),
            ],
            onChanged: _busy
                ? null
                : (id) => run(() async {
                    _camera = id == '' ? null : id;
                    await render();
                  }),
          ),
          DropdownButton<String>(
            value: _view,
            items: [
              for (final view in ['direct', 'top_down', 'bowl', 'split'])
                DropdownMenuItem(value: view, child: Text(view)),
            ],
            onChanged: _busy
                ? null
                : (view) => run(() async {
                    _view = view!;
                    await render();
                  }),
          ),
          Slider(
            value: _position.toDouble().clamp(
              (_session!['start_ns'] as int).toDouble(),
              ((_session!['end_ns'] as int) + 1).toDouble(),
            ),
            min: (_session!['start_ns'] as int).toDouble(),
            max: ((_session!['end_ns'] as int) + 1).toDouble(),
            onChangeStart: (_) => play(false),
            onChanged: _busy
                ? null
                : (value) => setState(() => _position = value.toInt()),
            onChangeEnd: _busy ? null : (_) => run(render),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : () => play(!_playing),
                child: Text(_playing ? 'Pause' : 'Play'),
              ),
              DropdownButton<double>(
                value: _speed,
                items: [
                  for (final speed in [.5, 1.0, 2.0])
                    DropdownMenuItem(value: speed, child: Text('$speed×')),
                ],
                onChanged: (speed) => setState(() => _speed = speed!),
              ),
            ],
          ),
          TextField(
            controller: _export,
            decoration: const InputDecoration(
              labelText: 'Individual track export path',
            ),
          ),
          DropdownButton<String>(
            value: _exportPolicy,
            items: const [
              DropdownMenuItem(
                value: 'passthrough',
                child: Text('Original packet export'),
              ),
              DropdownMenuItem(
                value: 'h264',
                child: Text('H.264 Matroska export'),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _exportPolicy = value!),
          ),
          button('Export selected track', () async {
            if (_camera == null) {
              throw StateError('Select one recorded camera to export.');
            }
            final result = await SurroundJob(widget.control).run('recording', {
              'action': 'export',
              'policy': _exportPolicy,
              'session': _session!['session'],
              'camera_id': _camera,
              'output': _export.text,
            });
            _status = {..._status, 'export': result};
          }),
        ],
      ],
    ),
  );
}
