import 'dart:async';

import 'package:flutter/material.dart';

import '../core/connectivity/connectivity_service.dart';
import '../features/projection/projection_input_scope.dart';

/// One device-scoped decision surface above the Navigator, including setup and
/// pushed routes. The daemon owns request expiry and Bluetooth authorization.
class PairingRequestOverlay extends StatefulWidget {
  const PairingRequestOverlay({
    super.key,
    required this.service,
    required this.child,
  });
  final ConnectivityService service;
  final Widget child;
  static const decisionTimeout = Duration(seconds: 5);
  @override
  State<PairingRequestOverlay> createState() => _PairingRequestOverlayState();
}

class _PairingRequestOverlayState extends State<PairingRequestOverlay> {
  StreamSubscription<ConnectivitySnapshot>? _subscription;
  late ConnectivitySnapshot _snapshot;
  Timer? _deadline;
  bool _pending = false;
  String? _error;
  int _epoch = 0;
  PairingPrompt? get _prompt => _snapshot.available && _snapshot.daemonConnected
      ? _snapshot.prompt
      : null;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    _snapshot = widget.service.connectivity;
    _subscription = widget.service.connectivityChanges.listen((snapshot) {
      if (!mounted) return;
      final previous = _prompt;
      setState(() {
        _snapshot = snapshot;
        final next = _prompt;
        if (previous?.id != next?.id || previous?.device != next?.device) {
          _epoch++;
          _deadline?.cancel();
          _pending = false;
          _error = null;
        }
      });
    });
  }

  @override
  void didUpdateWidget(covariant PairingRequestOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      unawaited(_subscription?.cancel());
      _deadline?.cancel();
      _epoch++;
      _pending = false;
      _error = null;
      _subscribe();
    }
  }

  Future<void> _respond(bool accept) async {
    final prompt = _prompt;
    if (prompt == null || _pending) return;
    final epoch = ++_epoch;
    setState(() {
      _pending = true;
      _error = null;
    });
    _deadline?.cancel();
    _deadline = Timer(PairingRequestOverlay.decisionTimeout, () {
      if (!mounted || epoch != _epoch || !_pending) return;
      setState(() {
        _pending = false;
        _error = 'The Bluetooth service has not confirmed the response. Try again while this request is visible.';
      });
    });
    try {
      await widget.service.connectivityCommand(
        'confirm',
        prompt: prompt.id,
        accept: accept,
      );
      // Keep controls disabled until the daemon withdraws this exact prompt.
    } on Object {
      if (!mounted || epoch != _epoch) return;
      _deadline?.cancel();
      setState(() {
        _pending = false;
        _error = 'Could not send the Bluetooth response. Try again.';
      });
    }
  }

  @override
  void dispose() {
    _epoch++;
    _deadline?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prompt = _prompt;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: prompt != null,
          child: ExcludeSemantics(
            excluding: prompt != null,
            child: ProjectionInputScope(
              active: true,
              blocked: prompt != null,
              child: widget.child,
            ),
          ),
        ),
        if (prompt != null) ...[
          const ModalBarrier(color: Colors.black54, dismissible: false),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: FocusScope(
                          autofocus: true,
                          child: FocusTraversalGroup(
                            child: Semantics(
                              scopesRoute: true,
                              namesRoute: true,
                              explicitChildNodes: true,
                              label: 'Bluetooth request',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Bluetooth request',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    prompt.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  Text(
                                    bluetoothAddress(
                                          prompt.device.split('/').last,
                                        ) ??
                                        prompt.device,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(prompt.text),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'This request expires automatically.',
                                  ),
                                  if (_pending) ...[
                                    const SizedBox(height: 12),
                                    const LinearProgressIndicator(),
                                    const Text('Waiting for the phone…'),
                                  ],
                                  if (_error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(
                                        _error!,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 16),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 8,
                                    children: [
                                      FilledButton(
                                        onPressed: _pending
                                            ? null
                                            : () => _respond(true),
                                        child: const Text('Allow'),
                                      ),
                                      OutlinedButton(
                                        onPressed: _pending
                                            ? null
                                            : () => _respond(false),
                                        child: const Text('Reject'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
