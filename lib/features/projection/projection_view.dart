import 'dart:async';
import 'dart:ui' show PointerDeviceKind, ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_touch_mapper.dart';
import '../../core/projection/projection_types.dart';
import 'ihs_projection_surface.dart';
import 'projection_input_scope.dart';

typedef ProjectionNativeViewBuilder = Widget Function(
  BuildContext context,
  String streamId,
);

/// Protocol-neutral projection surface. Pixels remain in the native IHS view;
/// Dart owns only layout, visibility, and normalized input metadata.
class ProjectionView extends StatefulWidget {
  const ProjectionView({
    super.key,
    required ProjectionService this.service,
    required String this.sessionId,
    required ProjectionVideoStream this.stream,
    this.nativeViewBuilder,
    this.inputEnabled = true,
  });

  const ProjectionView.rendererTest({super.key, this.nativeViewBuilder})
    : inputEnabled = false,
      service = null,
      sessionId = null,
      stream = null;

  bool get isRendererTest => service == null;

  static const viewType = 'argo.projection.view';

  final bool inputEnabled;
  final ProjectionService? service;
  final String? sessionId;
  final ProjectionVideoStream? stream;
  final ProjectionNativeViewBuilder? nativeViewBuilder;

  @override
  State<ProjectionView> createState() => _ProjectionViewState();
}

class _ProjectionViewState extends State<ProjectionView>
    with WidgetsBindingObserver {
  static const _mapper = ProjectionTouchMapper();
  final Map<int, _AcceptedPointer> _pointers = {};
  final List<_PendingTouch> _pending = [];
  bool _sending = false;
  bool _disposed = false;
  _InputTarget? _target;
  final List<_InputTarget> _targets = [];
  bool _moveScheduled = false;
  bool _ownsInput = true;
  bool _focused = true;
  int? _viewId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
    final active = ProjectionInputScope.activeOf(context);
    if (!active) _cancelAll();
    _ownsInput = active;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _focused = state == AppLifecycleState.resumed;
    if (!_focused) _cancelAll();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    if (!_focused) _cancelAll();
  }

  void _observePointer(PointerEvent event) {
    if (event is PointerRemovedEvent) {
      if (_pointers.values.any((p) => p.device == event.device)) _cancelAll();
    } else if (event.kind == PointerDeviceKind.mouse &&
        (event is PointerHoverEvent ||
            event is PointerAddedEvent ||
            event is PointerMoveEvent) &&
        event.buttons & kPrimaryMouseButton == 0 &&
        _pointers.values.any((p) => p.device == event.device)) {
      _cancelAll();
    }
  }

  void _cancelAll() {
    if (_pointers.isEmpty) return;
    // Android ACTION_CANCEL is gesture-wide. One terminal event clears both
    // ends, including every finger still tracked in this originating session.
    final pointer = _pointers.values.first;
    _pointers.clear();
    _queue(pointer, ProjectionTouchPhase.cancel, pointer.last);
  }

  void _queue(
    _AcceptedPointer pointer,
    ProjectionTouchPhase phase,
    ProjectionTouch position,
  ) {
    final touch = ProjectionTouch(
      pointerId: pointer.id,
      phase: phase,
      x: position.x,
      y: position.y,
    );
    if (phase == ProjectionTouchPhase.move) {
      _pending.removeWhere(
        (p) =>
            p.touch.phase == ProjectionTouchPhase.move &&
            p.touch.pointerId == pointer.id,
      );
    } else if (phase == ProjectionTouchPhase.up ||
        phase == ProjectionTouchPhase.cancel) {
      _pending.removeWhere((p) => p.touch.phase == ProjectionTouchPhase.move);
    }
    _pending.add(_PendingTouch(pointer.target, touch));
    if (phase != ProjectionTouchPhase.move) {
      unawaited(_drain());
    } else if (!_moveScheduled) {
      _moveScheduled = true;
      WidgetsBinding.instance.scheduleFrameCallback((_) {
        _moveScheduled = false;
        unawaited(_drain());
      });
    }
  }

  Future<void> _drain() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_pending.isNotEmpty) {
        final next = _pending.removeAt(0);
        // Never retarget queued input after unplug/session replacement.
        if (!next.target.valid || !next.target.isLive) continue;
        try {
          await next.target.service.sendTouch(next.target.session, next.touch);
        } on Object catch (error) {
          debugPrint('Argo projection: input delivery failed: $error');
        }
      }
    } finally {
      _sending = false;
      if (_disposed) {
        _closeTargets();
      } else {
        final retired = _targets
            .where(
              (target) =>
                  target != _target &&
                  !_pointers.values.any((p) => p.target == target),
            )
            .toList();
        for (final target in retired) {
          unawaited(target.subscription.cancel());
          _targets.remove(target);
        }
      }
    }
  }

  void _closeTargets() {
    for (final target in _targets) {
      unawaited(target.subscription.cancel());
    }
    _targets.clear();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_observePointer);
    _setTarget();
    unawaited(widget.service?.setVideoVisibility(widget.stream!.id, true));
  }

  void _setTarget() {
    if (widget.service == null) return;
    _target = _InputTarget(
      widget.service!,
      widget.sessionId!,
      widget.stream!.id,
    );
    _targets.add(_target!);
  }

  @override
  void didUpdateWidget(ProjectionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream?.id == widget.stream?.id &&
        oldWidget.sessionId == widget.sessionId &&
        oldWidget.service == widget.service) {
      if (!widget.inputEnabled ||
          widget.stream?.visible == false ||
          widget.stream?.focused == false) {
        _cancelAll();
      }
      return;
    }
    _cancelAll();
    _setTarget();
    unawaited(
      oldWidget.service?.setVideoVisibility(oldWidget.stream!.id, false),
    );
    unawaited(widget.service?.setVideoVisibility(widget.stream!.id, true));
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAll();
    if (!_sending && _pending.isEmpty) _closeTargets();
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_observePointer);
    unawaited(widget.service?.setVideoVisibility(widget.stream!.id, false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final geometry = ProjectionViewGeometry(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
      );
      return MouseRegion(
        onExit: (_) {
          if (_pointers.values.any((p) => p.kind == PointerDeviceKind.mouse)) {
            _cancelAll();
          }
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) =>
              _send(event, ProjectionTouchPhase.down, geometry),
          onPointerMove: (event) =>
              _send(event, ProjectionTouchPhase.move, geometry),
          onPointerUp: (event) =>
              _send(event, ProjectionTouchPhase.up, geometry),
          onPointerCancel: (event) =>
              _send(event, ProjectionTouchPhase.cancel, geometry),
          child: Center(
            child: AspectRatio(
              aspectRatio:
                  (widget.stream?.width ?? 1280) /
                  (widget.stream?.height ?? 720),
              child: IgnorePointer(child: _nativeView(context)),
            ),
          ),
        ),
      );
    },
  );

  Widget _nativeView(BuildContext context) {
    final builder = widget.nativeViewBuilder;
    if (builder != null) {
      return builder(context, widget.stream?.id ?? 'renderer-diagnostic');
    }
    return IhsProjectionSurface(
      viewType: ProjectionView.viewType,
      creationParams: <String, Object?>{
        if (widget.stream != null) 'streamId': widget.stream!.id,
      },
      diagnostics: widget.isRendererTest,
    );
  }

  void _send(
    PointerEvent event,
    ProjectionTouchPhase phase,
    ProjectionViewGeometry geometry,
  ) {
    if (widget.isRendererTest) return;
    final mapped = _mapper.map(
      stream: widget.stream!,
      view: geometry,
      pointerId: event.pointer,
      phase: phase,
      localX: event.localPosition.dx,
      localY: event.localPosition.dy,
    );
    if (phase == ProjectionTouchPhase.down) {
      if (!widget.inputEnabled ||
          !_ownsInput ||
          !_focused ||
          _target?.valid != true ||
          _target?.isLive != true ||
          widget.stream?.visible == false ||
          widget.stream?.focused == false ||
          mapped == null ||
          event.buttons != kPrimaryButton ||
          _pointers.containsKey(event.pointer) ||
          _pointers.length >= 10) {
        return;
      }
      final pointer = _AcceptedPointer(
        event.pointer,
        event.device,
        event.kind,
        _target!,
        mapped,
      );
      _pointers[event.pointer] = pointer;
      _queue(pointer, phase, mapped);
      return;
    }
    final pointer = _pointers[event.pointer];
    if (pointer == null) return;
    if (phase == ProjectionTouchPhase.cancel ||
        (event.kind == PointerDeviceKind.mouse &&
            phase == ProjectionTouchPhase.move &&
            (mapped == null || event.buttons != kPrimaryMouseButton))) {
      _cancelAll();
      return;
    }
    if (mapped != null) pointer.last = mapped;
    if (phase == ProjectionTouchPhase.up) {
      _pointers.remove(event.pointer);
      _queue(pointer, phase, pointer.last);
    } else if (mapped != null) {
      _queue(pointer, phase, mapped);
    }
  }
}

class _InputTarget {
  _InputTarget(this.service, this.session, this.stream) {
    subscription = service.changes.listen((_) {
      // Session IDs can be reused after reconnect. Once lost, this target must
      // never become valid again, even if that same ID later returns.
      if (!isLive) valid = false;
    });
  }
  final ProjectionService service;
  final String session;
  final String stream;
  late final StreamSubscription<ProjectionSnapshot> subscription;
  bool valid = true;
  bool get isLive => service.current.sessions.any(
    (s) =>
        s.id == session &&
        (s.state == ProjectionSessionState.streaming ||
            s.state == ProjectionSessionState.suspended ||
            s.state == ProjectionSessionState.ready),
  );
}

class _AcceptedPointer {
  _AcceptedPointer(this.id, this.device, this.kind, this.target, this.last);
  final int id;
  final int device;
  final PointerDeviceKind kind;
  final _InputTarget target;
  ProjectionTouch last;
}

class _PendingTouch {
  _PendingTouch(this.target, this.touch);
  final _InputTarget target;
  final ProjectionTouch touch;
}
