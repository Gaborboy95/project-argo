import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_touch_mapper.dart';
import '../../core/projection/projection_types.dart';

typedef ProjectionNativeViewBuilder = Widget Function(
  BuildContext context,
  String streamId,
);

/// Protocol-neutral projection surface. Pixels remain in the native IHS view;
/// Dart owns only layout, visibility, and normalized input metadata.
class ProjectionView extends StatefulWidget {
  const ProjectionView({
    super.key,
    required this.service,
    required this.sessionId,
    required this.stream,
    this.nativeViewBuilder,
  });

  static const viewType = 'argo.projection.view';

  final ProjectionService service;
  final String sessionId;
  final ProjectionVideoStream stream;
  final ProjectionNativeViewBuilder? nativeViewBuilder;

  @override
  State<ProjectionView> createState() => _ProjectionViewState();
}

class _ProjectionViewState extends State<ProjectionView> {
  static const _mapper = ProjectionTouchMapper();

  @override
  void initState() {
    super.initState();
    unawaited(widget.service.setVideoVisibility(widget.stream.id, true));
  }

  @override
  void didUpdateWidget(ProjectionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream.id == widget.stream.id) return;
    unawaited(oldWidget.service.setVideoVisibility(oldWidget.stream.id, false));
    unawaited(widget.service.setVideoVisibility(widget.stream.id, true));
  }

  @override
  void dispose() {
    unawaited(widget.service.setVideoVisibility(widget.stream.id, false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final geometry = ProjectionViewGeometry(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
      );
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) =>
            _send(event, ProjectionTouchPhase.down, geometry),
        onPointerMove: (event) =>
            _send(event, ProjectionTouchPhase.move, geometry),
        onPointerUp: (event) => _send(event, ProjectionTouchPhase.up, geometry),
        onPointerCancel: (event) =>
            _send(event, ProjectionTouchPhase.cancel, geometry),
        child: IgnorePointer(child: _nativeView(context)),
      );
    },
  );

  Widget _nativeView(BuildContext context) {
    final builder = widget.nativeViewBuilder;
    if (builder != null) return builder(context, widget.stream.id);
    return AndroidView(
      viewType: ProjectionView.viewType,
      creationParams: <String, Object?>{'streamId': widget.stream.id},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }

  void _send(
    PointerEvent event,
    ProjectionTouchPhase phase,
    ProjectionViewGeometry geometry,
  ) {
    final touch = _mapper.map(
      stream: widget.stream,
      view: geometry,
      pointerId: event.pointer,
      phase: phase,
      localX: event.localPosition.dx,
      localY: event.localPosition.dy,
    );
    if (touch != null) {
      unawaited(widget.service.sendTouch(widget.sessionId, touch));
    }
  }
}
