import 'package:flutter/material.dart';

import '../../core/media/media_session_service.dart';
import 'dashboard_media_strip.dart';
import 'dashboard_panel.dart';

/// One persistent surface: changing its height never changes projection layout.
class DashboardFloatingMedia extends StatefulWidget {
  const DashboardFloatingMedia({
    super.key,
    required this.collapsedHeight,
    required this.expandedHeight,
    required this.open,
    required this.onOpen,
    required this.onClose,
    required this.media,
    required this.scale,
  });
  final double collapsedHeight, expandedHeight, scale;
  final bool open;
  final VoidCallback onOpen, onClose;
  final MediaSessionService? media;
  @override
  State<DashboardFloatingMedia> createState() => _DashboardFloatingMediaState();
}

class _DashboardFloatingMediaState extends State<DashboardFloatingMedia>
    with SingleTickerProviderStateMixin {
  late final _extent = AnimationController(
    vsync: this,
    value: widget.open ? 1 : 0,
  );
  final _scroll = ScrollController();
  bool _dragging = false;
  double get _travel => (widget.expandedHeight - widget.collapsedHeight).clamp(
    1,
    double.infinity,
  );

  void _snap(bool open) {
    _extent.animateTo(
      open ? 1 : 0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    if (open) {
      widget.onOpen();
    } else {
      widget.onClose();
    }
  }

  @override
  void didUpdateWidget(covariant DashboardFloatingMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open && !_dragging) {
      _extent.animateTo(
        widget.open ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _extent.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _extent,
    builder: (context, _) {
      final height = widget.collapsedHeight + _extent.value * _travel;
      final blend = ((_extent.value - .15) / .55).clamp(0.0, 1.0);
      return SizedBox(
        key: const ValueKey('floating-media-surface'),
        height: height,
        child: PanelDragRegion(
          onStart: () {
            _dragging = true;
            _extent.stop();
          },
          onUpdate: (dy) {
            if (dy < 0 && _extent.value == 1 && _scroll.hasClients) {
              _scroll.jumpTo(
                (_scroll.offset - dy).clamp(
                  0,
                  _scroll.position.maxScrollExtent,
                ),
              );
              return;
            }
            _extent.value = (_extent.value - dy / _travel).clamp(0, 1);
            if (_extent.value > 0 && !widget.open) widget.onOpen();
          },
          onEnd: (velocity) {
            _dragging = false;
            _snap(velocity < -500 || (velocity < 500 && _extent.value > .4));
          },
          onCancel: () {
            if (_dragging) {
              _dragging = false;
              _snap(widget.open);
            }
          },
          child: Material(
            elevation: 6,
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (blend < 1)
                  Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      height: widget.collapsedHeight,
                      child: IgnorePointer(
                        ignoring: blend >= .5,
                        child: Opacity(
                          opacity: 1 - blend,
                          child: DashboardMediaStrip(
                            media: widget.media,
                            scale: widget.scale,
                            onOpen: () => _snap(true),
                            dragEnabled: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (blend > 0)
                  IgnorePointer(
                    ignoring: blend < .5,
                    child: Opacity(
                      opacity: blend,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        physics: const NeverScrollableScrollPhysics(),
                        child: DashboardMediaStrip(
                          media: widget.media,
                          scale: widget.scale,
                          expanded: true,
                          onDismiss: () => _snap(false),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
