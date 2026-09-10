import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// The sole vertical gesture owner for a panel (including its controls). Child
/// taps compete normally until touch slop; horizontal sliders keep their axis.
class PanelDragRegion extends StatelessWidget {
  const PanelDragRegion({
    super.key,
    required this.child,
    this.onStart,
    required this.onUpdate,
    required this.onEnd,
    this.onCancel,
  });
  final Widget child;
  final VoidCallback? onStart, onCancel;
  final ValueChanged<double> onUpdate, onEnd;
  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      _PanelVerticalDrag:
          GestureRecognizerFactoryWithHandlers<_PanelVerticalDrag>(
            _PanelVerticalDrag.new,
            (recognizer) {
              recognizer.onlyAcceptDragOnThreshold = true;
              recognizer.dragStartBehavior = DragStartBehavior.down;
              recognizer.onStart = (_) => onStart?.call();
              recognizer.onUpdate = (details) => onUpdate(details.delta.dy);
              recognizer.onEnd = (details) =>
                  onEnd(details.primaryVelocity ?? 0);
              recognizer.onCancel = onCancel;
            },
          ),
    },
    child: child,
  );
}

class _PanelVerticalDrag extends VerticalDragGestureRecognizer {
  Offset _origin = Offset.zero, _distance = Offset.zero;
  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origin = event.position;
    _distance = Offset.zero;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _distance = event.position - _origin;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind kind,
    double? slop,
  ) =>
      _distance.dy.abs() > kTouchSlop &&
      _distance.dy.abs() > _distance.dx.abs() * 1.2;
}

/// One animated sheet, one vertical recognizer and one scroll owner. There is
/// deliberately no nested vertical scroll recognizer to steal a control drag.
class DashboardPanel extends StatefulWidget {
  const DashboardPanel({
    super.key,
    required this.height,
    required this.onDismiss,
    required this.child,
    required this.label,
  });
  final double height;
  final VoidCallback onDismiss;
  final Widget child;
  final String label;
  @override
  State<DashboardPanel> createState() => _DashboardPanelState();
}

class _DashboardPanelState extends State<DashboardPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  );
  final _scroll = ScrollController();
  bool _closing = false, _dragging = false;
  @override
  void initState() {
    super.initState();
    _offset.value = widget.height;
    _offset.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _update(double delta) {
    if (_closing) return;
    _offset.stop();
    if (delta > 0 || _offset.value > 0) {
      _offset.value = (_offset.value + delta).clamp(0, widget.height);
    } else if (_scroll.hasClients) {
      _scroll.jumpTo(
        (_scroll.offset - delta).clamp(0, _scroll.position.maxScrollExtent),
      );
    }
  }

  void _end(double velocity) {
    if (_closing || !_dragging) return;
    _dragging = false;
    final dismiss =
        velocity > 650 ||
        (_offset.value > widget.height * .2 && velocity > -350);
    _closing = dismiss;
    _offset
        .animateTo(
          dismiss ? widget.height : 0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          if (mounted && dismiss) widget.onDismiss();
        });
  }

  @override
  void dispose() {
    _offset.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedBuilder(
      animation: _offset,
      builder: (context, child) =>
          Transform.translate(offset: Offset(0, _offset.value), child: child),
      child: PanelDragRegion(
        onStart: () {
          if (!_closing) {
            _dragging = true;
            _offset.stop();
          }
        },
        onUpdate: _update,
        onEnd: _end,
        onCancel: () {
          if (_dragging && !_closing) {
            _dragging = false;
            _offset.animateTo(
              0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
            );
          }
        },
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: FocusScope(
            autofocus: true,
            child: Semantics(
              scopesRoute: true,
              explicitChildNodes: true,
              namesRoute: true,
              label: widget.label,
              child: SingleChildScrollView(
                controller: _scroll,
                physics: const NeverScrollableScrollPhysics(),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
