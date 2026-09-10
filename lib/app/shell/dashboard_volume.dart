import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/audio/audio_service.dart';

/// One in-flight write plus one replaceable target. No pointer event backlog.
class DashboardVolume extends StatefulWidget {
  const DashboardVolume({
    super.key,
    required this.audio,
    required this.scale,
    required this.onIndicator,
  });
  final AudioService? audio;
  final double scale;
  final void Function(double?) onIndicator;
  @override
  State<DashboardVolume> createState() => _DashboardVolumeState();
}

class _DashboardVolumeState extends State<DashboardVolume>
    with WidgetsBindingObserver {
  int? _pointer;
  double _originY = 0, _originVolume = 0, _value = 0;
  bool _dragging = false, _sending = false;
  double? _pending;
  Timer? _cadence;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _finish(cancel: true);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.unfocused) _finish(cancel: true);
  }

  Future<void> _mute() async {
    if (widget.audio?.current.capabilities.mute != true) return;
    try {
      await widget.audio!.toggleMuted();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not mute host audio.')),
        );
      }
    }
  }

  void _queue(double value, {bool finalValue = false}) {
    _pending = value.clamp(0.0, 1.0);
    if (finalValue) {
      _cadence?.cancel();
      _cadence = null;
      _flush();
    } else {
      _cadence ??= Timer(const Duration(milliseconds: 40), () {
        _cadence = null;
        _flush();
      });
    }
  }

  Future<void> _flush() async {
    if (_sending || _pending == null) return;
    _sending = true;
    try {
      while (_pending != null) {
        final value = _pending!;
        _pending = null;
        await widget.audio?.setMasterVolume(value);
      }
    } on Object {
      _pending = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not change host volume.')),
        );
      }
    } finally {
      _sending = false;
    }
  }

  void _finish({bool cancel = false}) {
    if (_pointer == null) return;
    _pointer = null;
    // Cancellation retains the last live level, never reverses a heard change.
    if (_dragging) {
      _queue(_value, finalValue: true);
    } else if (!cancel) {
      unawaited(_mute());
    }
    _dragging = false;
    widget.onIndicator(null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cadence?.cancel();
    if (_dragging) {
      _pending = _value;
      unawaited(_flush());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Object?>(
    stream: widget.audio?.changes,
    builder: (context, _) {
      final state = widget.audio?.current;
      final enabled =
          state?.backendAvailable == true && state!.capabilities.masterVolume;
      return Semantics(
        label: 'Volume',
        value: '${((state?.masterVolume ?? 0) * 100).round()} percent',
        increasedValue: enabled
            ? '${((state.masterVolume + .05).clamp(0, 1) * 100).round()} percent'
            : null,
        decreasedValue: enabled
            ? '${((state.masterVolume - .05).clamp(0, 1) * 100).round()} percent'
            : null,
        enabled: enabled,
        button: true,
        onTap: enabled && state.capabilities.mute ? _mute : null,
        onIncrease: enabled
            ? () => _queue(state.masterVolume + .05, finalValue: true)
            : null,
        onDecrease: enabled
            ? () => _queue(state.masterVolume - .05, finalValue: true)
            : null,
        child: Listener(
          key: const ValueKey('dashboard-volume'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (!enabled || _pointer != null || e.buttons != kPrimaryButton) {
              return;
            }
            _pointer = e.pointer;
            _originY = e.position.dy;
            _originVolume = state.masterVolume;
            _value = _originVolume;
          },
          onPointerMove: (e) {
            if (e.pointer != _pointer) return;
            final delta = _originY - e.position.dy;
            if (!_dragging && delta.abs() < kTouchSlop) return;
            _dragging = true;
            final travel = (MediaQuery.sizeOf(context).height * .35).clamp(
              120.0,
              400.0,
            );
            _value = (_originVolume + delta / travel).clamp(0.0, 1.0);
            widget.onIndicator(_value);
            _queue(_value);
          },
          onPointerUp: (e) {
            if (e.pointer == _pointer) _finish();
          },
          onPointerCancel: (e) {
            if (e.pointer == _pointer) _finish(cancel: true);
          },
          child: Center(
            child: Icon(
              state?.muted == true
                  ? Icons.volume_off_outlined
                  : Icons.volume_up_outlined,
              size: 28 * widget.scale,
              color: enabled ? null : Theme.of(context).disabledColor,
            ),
          ),
        ),
      );
    },
  );
}
