import 'dart:async';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/vehicle/vehicle_transport_lifecycle.dart';

typedef CanProviderFactory = Future<CanProvider> Function();

final class CanTransportOfflineException implements Exception {
  const CanTransportOfflineException();

  @override
  String toString() => 'CAN transport is quiesced or offline.';
}

/// Stable Veloce-facing provider whose physical delegate can be recreated.
final class RestartableCanProvider
    implements CanProvider, VehicleTransportLifecycle {
  RestartableCanProvider._({
    required this._delegateFactory,
    required this.writesEnabled,
  });

  static Future<RestartableCanProvider> start({
    required CanProviderFactory delegateFactory,
    required bool writesEnabled,
  }) async {
    final provider = RestartableCanProvider._(
      delegateFactory: delegateFactory,
      writesEnabled: writesEnabled,
    );
    try {
      await provider.resume();
      return provider;
    } on Object catch (error, stackTrace) {
      try {
        await provider.close();
      } on Object {
        // Preserve the delegate startup failure.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  final CanProviderFactory _delegateFactory;

  @override
  final bool writesEnabled;

  final Map<int, _LogicalCanSubscription> _subscriptions = {};
  final List<CanProvider> _detachedDelegates = [];
  Future<void> _operationTail = Future<void>.value();
  CanProvider? _delegate;
  Future<void>? _closeFuture;
  var _nextSubscriptionId = 1;
  var _transportGeneration = 0;
  var _acceptFrames = false;
  var _closed = false;

  bool get isOnline => _delegate != null && _acceptFrames && !_closed;

  @override
  Future<CanSubscription> subscribe({
    required String ownerId,
    required CanFilter filter,
    required CanFrameHandler onFrame,
  }) => _serialize(() async {
    _ensureOpen();
    if (ownerId.trim().isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'Must not be empty');
    }

    final subscription = _LogicalCanSubscription(
      id: _nextSubscriptionId++,
      ownerId: ownerId,
      filter: filter,
      handler: onFrame,
      cancelLogical: _cancelSubscription,
    );
    final delegate = _delegate;
    if (delegate != null) {
      final generation = _transportGeneration;
      subscription.delegateSubscription = await _attach(
        delegate,
        subscription,
        generation,
      );
      subscription.delegateGeneration = generation;
    }
    _subscriptions[subscription.id] = subscription;
    return subscription;
  });

  @override
  Future<void> send({required String ownerId, required CanFrame frame}) {
    if (_delegate == null || !_acceptFrames) {
      return Future.error(const CanTransportOfflineException());
    }
    return _serialize(() async {
      _ensureOpen();
      final delegate = _delegate;
      if (delegate == null || !_acceptFrames) {
        throw const CanTransportOfflineException();
      }
      await delegate.send(ownerId: ownerId, frame: frame);
    });
  }

  @override
  Future<void> removeOwner(String ownerId) => _serialize(() async {
    final subscriptions = _subscriptions.values
        .where((subscription) => subscription.ownerId == ownerId)
        .toList(growable: false);
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final subscription in subscriptions) {
      _subscriptions.remove(subscription.id);
      subscription.active = false;
      final delegateSubscription = subscription.delegateSubscription;
      subscription.delegateSubscription = null;
      subscription.delegateGeneration = null;
      if (delegateSubscription == null) continue;
      try {
        await delegateSubscription.cancel();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  });

  @override
  Future<void> quiesce() => _serialize(() async {
    _ensureOpen();
    if (_delegate == null) {
      await _closeDetachedDelegates();
      return;
    }

    _acceptFrames = false;
    _transportGeneration++;
    final delegate = _delegate!;
    _delegate = null;
    for (final subscription in _subscriptions.values) {
      subscription
        ..delegateSubscription = null
        ..delegateGeneration = null;
    }
    try {
      await delegate.close();
    } on Object catch (error, stackTrace) {
      _detachedDelegates.add(delegate);
      Error.throwWithStackTrace(error, stackTrace);
    }
  });

  @override
  Future<void> resume() => _serialize(() async {
    _ensureOpen();
    if (_delegate != null) return;
    await _closeDetachedDelegates();

    CanProvider? candidate;
    final attached = <_LogicalCanSubscription, CanSubscription>{};
    final generation = ++_transportGeneration;
    try {
      candidate = await _delegateFactory();
      if (candidate.writesEnabled != writesEnabled) {
        throw StateError(
          'Recreated CAN provider changed writesEnabled from '
          '$writesEnabled to ${candidate.writesEnabled}.',
        );
      }
      for (final subscription in _subscriptions.values) {
        if (!subscription.active) continue;
        attached[subscription] = await _attach(
          candidate,
          subscription,
          generation,
        );
      }
      for (final entry in attached.entries) {
        entry.key
          ..delegateSubscription = entry.value
          ..delegateGeneration = generation;
      }
      _delegate = candidate;
      _acceptFrames = true;
    } on Object catch (error, stackTrace) {
      _acceptFrames = false;
      _delegate = null;
      for (final subscription in _subscriptions.values) {
        subscription
          ..delegateSubscription = null
          ..delegateGeneration = null;
      }
      if (candidate != null) {
        try {
          await candidate.close();
        } on Object {
          _detachedDelegates.add(candidate);
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  });

  Future<CanSubscription> _attach(
    CanProvider delegate,
    _LogicalCanSubscription subscription,
    int generation,
  ) => delegate.subscribe(
    ownerId: subscription.ownerId,
    filter: subscription.filter,
    onFrame: (frame) async {
      if (!_acceptFrames ||
          !subscription.active ||
          subscription.delegateGeneration != generation) {
        return;
      }
      await subscription.handler(frame);
    },
  );

  Future<void> _cancelSubscription(int id) => _serialize(() async {
    final subscription = _subscriptions.remove(id);
    if (subscription == null || !subscription.active) return;
    subscription.active = false;
    final delegateSubscription = subscription.delegateSubscription;
    subscription.delegateSubscription = null;
    subscription.delegateGeneration = null;
    await delegateSubscription?.cancel();
  });

  Future<void> _closeDetachedDelegates() async {
    if (_detachedDelegates.isEmpty) return;
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final delegate in List<CanProvider>.of(_detachedDelegates)) {
      try {
        await delegate.close();
        _detachedDelegates.remove(delegate);
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _serialize(_close);

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _acceptFrames = false;
    _transportGeneration++;
    final subscriptions = _subscriptions.values.toList(growable: false);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      subscription
        ..active = false
        ..delegateSubscription = null
        ..delegateGeneration = null;
    }

    final delegates = <CanProvider>[?_delegate, ..._detachedDelegates];
    _delegate = null;
    _detachedDelegates.clear();
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final delegate in delegates) {
      try {
        await delegate.close();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _ensureOpen() {
    if (_closed || _closeFuture != null) {
      throw StateError('Restartable CAN provider is closed.');
    }
  }
}

final class _LogicalCanSubscription implements CanSubscription {
  _LogicalCanSubscription({
    required this.id,
    required this.ownerId,
    required this.filter,
    required this.handler,
    required this._cancelLogical,
  });

  final int id;
  @override
  final String ownerId;
  @override
  final CanFilter filter;
  final CanFrameHandler handler;
  final Future<void> Function(int id) _cancelLogical;
  CanSubscription? delegateSubscription;
  int? delegateGeneration;
  bool active = true;

  @override
  Future<void> cancel() => _cancelLogical(id);
}
