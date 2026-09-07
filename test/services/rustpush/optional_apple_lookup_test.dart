import 'dart:async';

import 'package:bluebubbles/services/rustpush/optional_apple_lookup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('route changes invalidate optional lookup results', () {
    bool matches(String? handle, List<String> peers) =>
        optionalAppleRouteMatches(
          capturedHandle: 'mailto:sender@example.com',
          currentHandle: handle,
          capturedPeers: ['mailto:peer@example.com'],
          currentPeers: peers,
        );
    expect(
      matches('mailto:sender@example.com', ['mailto:peer@example.com']),
      isTrue,
    );
    expect(matches(null, ['mailto:peer@example.com']), isFalse);
    expect(
      matches('mailto:other@example.com', ['mailto:peer@example.com']),
      isFalse,
    );
    expect(
      matches('mailto:sender@example.com', ['mailto:other@example.com']),
      isFalse,
    );
    expect(matches('mailto:sender@example.com', []), isFalse);
  });

  test('cancelled lookup disposes a result once instead of installing it', () {
    final fence = OptionalLookupFence();
    final generation = fence.begin();
    fence.cancel();
    var disposals = 0;
    expect(
      fence.acceptResource(
        generation: generation,
        resource: _Resource('cancelled'),
        contextIsCurrent: true,
        dispose: (_) => disposals++,
      ),
      isNull,
    );
    expect(disposals, 1);
  });

  test('current lookup transfers resource ownership without disposing it', () {
    final fence = OptionalLookupFence();
    final generation = fence.begin();
    final resource = _Resource('current');
    expect(
      fence.acceptResource(
        generation: generation,
        resource: resource,
        contextIsCurrent: true,
        dispose: (_) => fail('current owner must retain resource'),
      ),
      same(resource),
    );
  });

  test('optional validation accepts only the captured live handle', () async {
    expect(
      await validateOptionalAppleHandle(
        selectedHandle: 'mailto:current@example.com',
        getLiveHandles: () async => ['mailto:current@example.com'],
      ),
      'mailto:current@example.com',
    );
    expect(
      await validateOptionalAppleHandle(
        selectedHandle: 'tel:+15550000000',
        getLiveHandles: () async => ['mailto:current@example.com'],
      ),
      isNull,
    );
  });

  test('missing handles and lookup errors remain optional', () async {
    expect(
      await validateOptionalAppleHandle(
        selectedHandle: null,
        getLiveHandles: () async => throw StateError('must not run'),
      ),
      isNull,
    );
    expect(
      await validateOptionalAppleHandle(
        selectedHandle: 'mailto:current@example.com',
        getLiveHandles: () async => throw StateError('offline'),
      ),
      isNull,
    );
  });

  test('navigation invalidates an outstanding lookup', () {
    final fence = OptionalLookupFence();
    final first = fence.begin();
    final second = fence.begin();

    expect(fence.isCurrent(first), isFalse);
    expect(fence.isCurrent(second), isTrue);
  });

  test(
    'late resources are disposed instead of replacing current state',
    () async {
      final fence = OptionalLookupFence();
      final first = fence.begin();
      final late = Completer<_Resource>();
      final disposal = <String>[];

      final resultFuture = late.future.then(
        (resource) => fence.acceptResource(
          generation: first,
          resource: resource,
          contextIsCurrent: true,
          dispose: (value) => disposal.add(value.name),
        ),
      );
      fence.begin();
      late.complete(_Resource('late'));

      expect(await resultFuture, isNull);
      expect(disposal, ['late']);
    },
  );

  test('changed account or chat context rejects and disposes a resource', () {
    final fence = OptionalLookupFence();
    final generation = fence.begin();
    var disposed = false;

    final accepted = fence.acceptResource(
      generation: generation,
      resource: _Resource('wrong-context'),
      contextIsCurrent: false,
      dispose: (_) => disposed = true,
    );

    expect(accepted, isNull);
    expect(disposed, isTrue);
  });
}

class _Resource {
  _Resource(this.name);

  final String name;
}
