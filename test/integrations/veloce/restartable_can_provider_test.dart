import 'dart:async';

import 'package:argo/integrations/veloce/restartable_can_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  final filter = CanFilter(bus: 'comfort', id: 0x280);
  final frame = CanFrame(bus: 'comfort', id: 0x280, data: const [11, 184]);

  test(
    'creates an initial delegate and restores logical subscriptions',
    () async {
      final delegates = <_TestCanProvider>[];
      final provider = await RestartableCanProvider.start(
        delegateFactory: () async {
          final delegate = _TestCanProvider();
          delegates.add(delegate);
          return delegate;
        },
        writesEnabled: false,
      );
      addTearDown(provider.close);
      final received = <CanFrame>[];
      await provider.subscribe(
        ownerId: 'plugin.one',
        filter: filter,
        onFrame: received.add,
      );

      delegates.single.inject(frame);
      await delegates.single.flush();
      expect(received, hasLength(1));

      await provider.quiesce();
      expect(provider.isOnline, isFalse);
      expect(delegates.single.closeCalls, 1);

      await provider.resume();
      expect(delegates, hasLength(2));
      expect(provider.isOnline, isTrue);
      expect(delegates.last.subscriptionCalls, 1);
      delegates.last.inject(frame);
      await delegates.last.flush();
      expect(received, hasLength(2));
    },
  );

  test('subscription cancelled while quiesced does not return', () async {
    final delegates = <_TestCanProvider>[];
    final provider = await _providerWithDelegates(delegates);
    addTearDown(provider.close);
    final subscription = await provider.subscribe(
      ownerId: 'plugin.one',
      filter: filter,
      onFrame: (_) {},
    );

    await provider.quiesce();
    await subscription.cancel();
    await provider.resume();

    expect(delegates.last.subscriptionCalls, 0);
  });

  test('subscription created while quiesced attaches on resume', () async {
    final delegates = <_TestCanProvider>[];
    final provider = await _providerWithDelegates(delegates);
    addTearDown(provider.close);
    await provider.quiesce();

    await provider.subscribe(
      ownerId: 'plugin.new',
      filter: filter,
      onFrame: (_) {},
    );
    expect(delegates.single.subscriptionCalls, 0);
    await provider.resume();

    expect(delegates.last.subscriptionCalls, 1);
  });

  test('removeOwner while quiesced survives resume', () async {
    final delegates = <_TestCanProvider>[];
    final provider = await _providerWithDelegates(delegates);
    addTearDown(provider.close);
    await provider.subscribe(
      ownerId: 'plugin.remove',
      filter: filter,
      onFrame: (_) {},
    );
    await provider.subscribe(
      ownerId: 'plugin.keep',
      filter: filter,
      onFrame: (_) {},
    );

    await provider.quiesce();
    await provider.removeOwner('plugin.remove');
    await provider.resume();

    expect(delegates.last.subscribedOwners, ['plugin.keep']);
  });

  test('send while quiesced fails and is never replayed', () async {
    final delegates = <_TestCanProvider>[];
    final provider = await _providerWithDelegates(
      delegates,
      writesEnabled: true,
    );
    addTearDown(provider.close);
    await provider.quiesce();

    await expectLater(
      provider.send(ownerId: 'plugin.one', frame: frame),
      throwsA(isA<CanTransportOfflineException>()),
    );
    await provider.resume();

    expect(delegates.last.sentFrames, isEmpty);
  });

  test('delegate factory failure leaves the proxy offline', () async {
    var factoryCalls = 0;
    final first = _TestCanProvider();
    final provider = await RestartableCanProvider.start(
      delegateFactory: () async {
        factoryCalls++;
        if (factoryCalls == 1) return first;
        throw StateError('socket unavailable');
      },
      writesEnabled: false,
    );
    addTearDown(provider.close);
    await provider.quiesce();

    await expectLater(provider.resume(), throwsA(isA<StateError>()));

    expect(provider.isOnline, isFalse);
    expect(factoryCalls, 2);
  });

  test('partial subscription recreation discards the new delegate', () async {
    final first = _TestCanProvider();
    final failing = _TestCanProvider(failSubscriptionAt: 2);
    var factoryCalls = 0;
    final provider = await RestartableCanProvider.start(
      delegateFactory: () async => factoryCalls++ == 0 ? first : failing,
      writesEnabled: false,
    );
    addTearDown(provider.close);
    await provider.subscribe(
      ownerId: 'plugin.one',
      filter: filter,
      onFrame: (_) {},
    );
    await provider.subscribe(
      ownerId: 'plugin.two',
      filter: filter,
      onFrame: (_) {},
    );
    await provider.quiesce();

    await expectLater(provider.resume(), throwsA(isA<StateError>()));

    expect(provider.isOnline, isFalse);
    expect(failing.closeCalls, 1);
  });

  test('close is terminal and idempotent', () async {
    final delegates = <_TestCanProvider>[];
    final provider = await _providerWithDelegates(delegates);

    await provider.close();
    await provider.close();

    expect(delegates.single.closeCalls, 1);
    await expectLater(provider.resume(), throwsA(isA<StateError>()));
    await expectLater(
      provider.subscribe(
        ownerId: 'plugin.one',
        filter: filter,
        onFrame: (_) {},
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('lifecycle and subscription mutations are serialized', () async {
    final closeStarted = Completer<void>();
    final releaseClose = Completer<void>();
    final delegates = <_TestCanProvider>[];
    final provider = await RestartableCanProvider.start(
      delegateFactory: () async {
        final delegate = _TestCanProvider(
          closeStarted: delegates.isEmpty ? closeStarted : null,
          releaseClose: delegates.isEmpty ? releaseClose : null,
        );
        delegates.add(delegate);
        return delegate;
      },
      writesEnabled: false,
    );
    addTearDown(provider.close);

    final quiesce = provider.quiesce();
    await closeStarted.future;
    var subscribeCompleted = false;
    final subscribe = provider
        .subscribe(
          ownerId: 'plugin.during-quiesce',
          filter: filter,
          onFrame: (_) {},
        )
        .whenComplete(() => subscribeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(subscribeCompleted, isFalse);

    releaseClose.complete();
    await quiesce;
    await subscribe;
    await provider.resume();

    expect(delegates.last.subscribedOwners, ['plugin.during-quiesce']);
  });
}

Future<RestartableCanProvider> _providerWithDelegates(
  List<_TestCanProvider> delegates, {
  bool writesEnabled = false,
}) => RestartableCanProvider.start(
  delegateFactory: () async {
    final delegate = _TestCanProvider(writesEnabled: writesEnabled);
    delegates.add(delegate);
    return delegate;
  },
  writesEnabled: writesEnabled,
);

final class _TestCanProvider implements CanProvider {
  _TestCanProvider({
    this.writesEnabled = false,
    this.failSubscriptionAt,
    this.closeStarted,
    this.releaseClose,
  }) : _memory = InMemoryCanProvider(writesEnabled: writesEnabled);

  @override
  final bool writesEnabled;
  final int? failSubscriptionAt;
  final Completer<void>? closeStarted;
  final Completer<void>? releaseClose;
  final InMemoryCanProvider _memory;
  final List<String> subscribedOwners = [];
  var subscriptionCalls = 0;
  var closeCalls = 0;
  var _closed = false;

  List<CanFrame> get sentFrames => _memory.sentHistory;

  CanInjectionResult inject(CanFrame frame) => _memory.inject(frame);

  Future<void> flush() => _memory.flush();

  @override
  Future<CanSubscription> subscribe({
    required String ownerId,
    required CanFilter filter,
    required CanFrameHandler onFrame,
  }) async {
    subscriptionCalls++;
    if (subscriptionCalls == failSubscriptionAt) {
      throw StateError('subscription recreation failed');
    }
    subscribedOwners.add(ownerId);
    return _memory.subscribe(
      ownerId: ownerId,
      filter: filter,
      onFrame: onFrame,
    );
  }

  @override
  Future<void> send({required String ownerId, required CanFrame frame}) =>
      _memory.send(ownerId: ownerId, frame: frame);

  @override
  Future<void> removeOwner(String ownerId) => _memory.removeOwner(ownerId);

  @override
  Future<void> close() async {
    if (_closed) return;
    closeCalls++;
    if (closeStarted != null && !closeStarted!.isCompleted) {
      closeStarted!.complete();
    }
    if (releaseClose != null) await releaseClose!.future;
    _closed = true;
    await _memory.close();
  }
}
