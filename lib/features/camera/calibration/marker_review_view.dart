import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/camera/calibration_manager.dart';
import '../ihs_camera_surface.dart';

class MarkerReviewView extends StatefulWidget {
  const MarkerReviewView({
    super.key,
    required this.manager,
    required this.observation,
    required this.changed,
    required this.redetect,
  });
  final CalibrationManager manager;
  final Map<String, dynamic> observation;
  final VoidCallback changed, redetect;
  @override
  State<MarkerReviewView> createState() => _MarkerReviewState();
}

class _MarkerReviewState extends State<MarkerReviewView> {
  final _undo = <Map<String, dynamic>>[];
  late final Map<String, dynamic> _baseline;
  int _selected = 0;
  bool _zoom = false, _showing = false;
  List<num> _origin = [0, 0];
  String? _error;
  List<dynamic> get points => widget.observation['corners'] as List;
  List<dynamic> get disabled =>
      widget.observation.putIfAbsent('disabled', () => []) as List;
  double get width => _zoom
      ? (widget.observation['image_size'][0] as num).toDouble().clamp(1, 320)
      : (widget.observation['image_size'][0] as num).toDouble();
  double get height => _zoom
      ? (widget.observation['image_size'][1] as num).toDouble().clamp(1, 240)
      : (widget.observation['image_size'][1] as num).toDouble();
  @override
  void initState() {
    super.initState();
    _baseline =
        jsonDecode(jsonEncode(widget.observation)) as Map<String, dynamic>;
    widget.observation['corners'] = List<dynamic>.from(
      widget.observation['corners'] as List,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _show());
  }

  Future<void> _show() async {
    if (!mounted || _showing) return;
    setState(() => _showing = true);
    try {
      if (_zoom) {
        final crop = await widget.manager.call('marker_loupe', {
          'image': widget.observation['image'],
          'pixel': points[_selected],
        });
        if (!mounted) return;
        _origin = (crop['origin'] as List).cast<num>();
        await widget.manager.present(
          crop['path'] as String,
          crop['width'] as int,
          crop['height'] as int,
          isCurrent: () => mounted,
        );
      } else {
        _origin = [0, 0];
        await widget.manager.present(
          widget.observation['image'] as String,
          width.toInt(),
          height.toInt(),
          isCurrent: () => mounted,
        );
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _showing = false);
  }

  void _remember() {
    _undo.add(
      jsonDecode(jsonEncode(widget.observation)) as Map<String, dynamic>,
    );
    if (_undo.length > 32) _undo.removeAt(0);
  }

  void _restore(Map<String, dynamic> snapshot) {
    setState(() {
      widget.observation
        ..clear()
        ..addAll(jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>);
    });
    widget.changed();
    if (_zoom) _show();
  }

  void _move(Offset local, Size size) {
    setState(
      () => points[_selected] = [
        (local.dx / size.width * width + _origin[0]).clamp(
          0,
          (widget.observation['image_size'][0] as num) - 1,
        ),
        (local.dy / size.height * height + _origin[1]).clamp(
          0,
          (widget.observation['image_size'][1] as num) - 1,
        ),
      ],
    );
    widget.observation['manual_correction'] = true;
    (widget.observation['manual_required'] as List?)?.remove(_selected);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text(
        'Confirm point 1 is the measured first inner corner. Checkerboards do not encode their origin. Select a point, then drag it; magnify for fine adjustment.',
      ),
      if (_error != null) Text(_error!),
      SizedBox(
        height: 340,
        child: AspectRatio(
          aspectRatio: width / height,
          child: LayoutBuilder(
            builder: (context, bounds) => GestureDetector(
              key: const ValueKey('marker-image-interaction'),
              behavior: HitTestBehavior.opaque,
              onPanStart: _showing
                  ? null
                  : (d) {
                      _remember();
                      _move(d.localPosition, bounds.biggest);
                    },
              onPanUpdate: _showing
                  ? null
                  : (d) => _move(d.localPosition, bounds.biggest),
              onPanEnd: (_) => widget.changed(),
              onTapUp: (d) {
                if (_showing) return;
                if (_zoom) {
                  _remember();
                  _move(d.localPosition, bounds.biggest);
                  widget.changed();
                } else {
                  var best = double.infinity;
                  var selected = _selected;
                  for (var i = 0; i < points.length; i++) {
                    final p = points[i] as List;
                    final distance =
                        (Offset(
                                  (p[0] as num).toDouble() /
                                      width *
                                      bounds.maxWidth,
                                  (p[1] as num).toDouble() /
                                      height *
                                      bounds.maxHeight,
                                ) -
                                d.localPosition)
                            .distance;
                    if (distance < best) {
                      best = distance;
                      selected = i;
                    }
                  }
                  setState(() => _selected = selected);
                }
              },
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: IhsCameraSurface(external: true),
                    ),
                  ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _Markers(
                        points,
                        disabled,
                        _selected,
                        width,
                        height,
                        _origin,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      Text('Point ${_selected + 1} • pixel ${points[_selected]}'),
      if (widget.observation['manual_seed'] == true)
        Text(
          '${(widget.observation['manual_required'] as List).where((i) => !disabled.contains(i)).length} enabled anchors still need placement',
        ),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: _showing
                ? null
                : () async {
                    setState(
                      () => _selected =
                          (_selected - 1 + points.length) % points.length,
                    );
                    if (_zoom) await _show();
                  },
            child: const Text('Previous'),
          ),
          TextButton(
            onPressed: _showing
                ? null
                : () async {
                    setState(() => _selected = (_selected + 1) % points.length);
                    if (_zoom) await _show();
                  },
            child: const Text('Next'),
          ),
          TextButton(
            onPressed: _showing
                ? null
                : () async {
                    setState(() => _zoom = !_zoom);
                    await _show();
                  },
            child: Text(_zoom ? 'Full image' : 'Magnify'),
          ),
          TextButton(
            onPressed: _showing
                ? null
                : () {
                    _remember();
                    setState(
                      () => points[_selected] = List<dynamic>.from(
                        widget.observation['original_corners'][_selected]
                            as List,
                      ),
                    );
                    if (widget.observation['manual_seed'] == true) {
                      final pending =
                          widget.observation['manual_required'] as List;
                      if (!pending.contains(_selected)) pending.add(_selected);
                    }
                    widget.changed();
                  },
            child: const Text('Reset point'),
          ),
          TextButton(
            onPressed: _showing
                ? null
                : () {
                    _remember();
                    setState(() {
                      if (disabled.contains(_selected)) {
                        disabled.remove(_selected);
                      } else if (points.length - disabled.length > 6) {
                        disabled.add(_selected);
                      }
                    });
                    widget.changed();
                  },
            child: const Text('Disable / enable point'),
          ),
          TextButton(
            onPressed: _showing
                ? null
                : () {
                    _remember();
                    setState(() {
                      final count = points.length;
                      widget.observation['corners'] = points.reversed.toList();
                      widget.observation['original_corners'] =
                          (widget.observation['original_corners'] as List)
                              .reversed
                              .toList();
                      widget.observation['disabled'] = disabled
                          .map((i) => count - 1 - (i as int))
                          .toList();
                      if (widget.observation['manual_required'] is List) {
                        widget.observation['manual_required'] =
                            (widget.observation['manual_required'] as List)
                                .map((i) => count - 1 - (i as int))
                                .toList();
                      }
                      widget.observation['ordering_confirmed'] = false;
                    });
                    widget.changed();
                  },
            child: const Text('Reverse corner order'),
          ),
          TextButton(
            onPressed: _showing || _undo.isEmpty
                ? null
                : () => _restore(_undo.removeLast()),
            child: const Text('Undo correction'),
          ),
          TextButton(
            onPressed: _showing
                ? null
                : () {
                    _remember();
                    _restore(_baseline);
                  },
            child: const Text('Reset camera points'),
          ),
          TextButton(
            onPressed: _showing ? null : widget.redetect,
            child: const Text('Re-detect camera'),
          ),
        ],
      ),
      CheckboxListTile(
        value: widget.observation['ordering_confirmed'] == true,
        onChanged: _showing
            ? null
            : (v) {
                _remember();
                setState(() => widget.observation['ordering_confirmed'] = v);
                widget.changed();
              },
        title: const Text(
          'Point 1 and row direction match my measured mat placement',
        ),
      ),
    ],
  );
}

class _Markers extends CustomPainter {
  _Markers(
    this.points,
    this.disabled,
    this.selected,
    this.width,
    this.height,
    this.origin,
  );
  final List points, disabled;
  final int selected;
  final double width, height;
  final List<num> origin;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    for (var i = 0; i < points.length; i++) {
      final p = points[i] as List;
      final at = Offset(
        ((p[0] as num) - origin[0]) / width * size.width,
        ((p[1] as num) - origin[1]) / height * size.height,
      );
      final color = disabled.contains(i)
          ? Colors.grey
          : i == selected
          ? Colors.yellow
          : Colors.cyan;
      canvas.drawCircle(
        at,
        i == selected ? 8 : 4,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      if (i == selected || i == 0) {
        final text = TextPainter(
          text: TextSpan(
            text: '${i + 1}',
            style: TextStyle(color: color, fontSize: 16),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(canvas, at + const Offset(7, 0));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Markers old) => true;
}
