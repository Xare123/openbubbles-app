// Proves the exact bridge-ownership requirement for setup-push retries: one
// saved APSState snapshot must be usable twice without disposing the caller's
// wrapper, matching the already-borrowed config and identity. Uses the real
// generated setup_push encoder, not a copied branch or a source grep. Only
// the native allocator/dispatcher and opaque handles are synthetic. No
// library, account, device, network request or production state is opened.
// ignore_for_file: subtype_of_sealed_class, implementation_imports, non_constant_identifier_names
import 'dart:ffi' as ffi;

import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/frb_generated.io.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_rust_bridge/src/generalized_frb_rust_binding/generalized_frb_rust_binding.dart';
import 'package:flutter_rust_bridge/src/main_components/port_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _EncodedOnly implements Exception {}

class _Handler extends BaseHandler {
  @override
  Future<S> executeNormal<S, E extends Object>(NormalTask<S, E> task) async {
    task.callFfi(1);
    throw _EncodedOnly();
  }
}

class _Binding extends Fake implements GeneralizedFrbRustBinding {
  final allocations = <ffi.Pointer<ffi.Uint8>>{};
  int dispatched = 0;

  @override
  ffi.Pointer<ffi.Uint8> rustVecU8New(int len) {
    final pointer = calloc<ffi.Uint8>(len);
    allocations.add(pointer);
    return pointer;
  }

  @override
  ffi.Pointer<ffi.Uint8> rustVecU8Resize(
    ffi.Pointer<ffi.Uint8> ptr,
    int oldLen,
    int newLen,
  ) {
    final replacement = rustVecU8New(newLen);
    replacement
        .asTypedList(newLen)
        .setRange(0, oldLen, ptr.asTypedList(oldLen));
    rustVecU8Free(ptr, oldLen);
    return replacement;
  }

  @override
  void rustVecU8Free(ffi.Pointer<ffi.Uint8> ptr, int len) {
    expect(allocations.remove(ptr), isTrue);
    calloc.free(ptr);
  }

  @override
  void pdeFfiDispatcherPrimary({
    required int funcId,
    required int port,
    required ffi.Pointer<ffi.Uint8> ptr,
    required int rustVecLen,
    required int dataLen,
  }) {
    dispatched++;
    expect(dataLen, greaterThan(0));
    rustVecU8Free(ptr, rustVecLen);
  }

  void close() {
    for (final pointer in allocations.toList()) {
      rustVecU8Free(pointer, 0);
    }
  }
}

class _Wire extends Fake implements RustLibWire {}

class _Ports extends Fake implements PortManager {}

// Generated encoders cast to these implementation types. Recording move mode
// here detects actual generated ownership transfers without any native pointer.
class _Handle extends Fake
    implements JoinedOsConfigImpl, IdsngmIdentityImpl, ApsStateImpl {
  bool disposed = false;
  final moveModes = <bool?>[];

  @override
  bool get isDisposed => disposed;

  @override
  void dispose() => disposed = true;

  @override
  BigInt frbInternalSseEncode({bool? move}) {
    if (disposed) throw StateError('synthetic handle was already moved');
    moveModes.add(move);
    if (move == true) disposed = true;
    return BigInt.one;
  }
}

class _Encoder extends RustLibApiImpl {
  _Encoder(_Binding binding)
    : super(
        handler: _Handler(),
        wire: _Wire(),
        generalizedFrbRustBinding: binding,
        portManager: _Ports(),
      );
}

void main() {
  test('setupPush borrows config and identity across repeated bridge calls',
      () async {
    final binding = _Binding();
    addTearDown(binding.close);
    final encoder = _Encoder(binding);
    final config = _Handle();
    final identity = _Handle();
    for (var repeat = 0; repeat < 2; repeat++) {
      await expectLater(
        encoder.crateApiApiSetupPush(
          config: config,
          identity: identity,
          state: null,
          statePath: 'synthetic-no-account',
        ),
        throwsA(isA<_EncodedOnly>()),
      );
    }
    expect(config.isDisposed, isFalse);
    expect(identity.isDisposed, isFalse);
    expect(config.moveModes, [false, false]);
    expect(identity.moveModes, [false, false]);
    expect(binding.dispatched, 2);
    expect(binding.allocations, isEmpty);
  });

  test(
      'setupPush reuses one APSState snapshot across retries without consuming it',
      () async {
    final binding = _Binding();
    addTearDown(binding.close);
    final encoder = _Encoder(binding);
    final config = _Handle();
    final identity = _Handle();
    final snapshot = _Handle();
    for (var repeat = 0; repeat < 2; repeat++) {
      await expectLater(
        encoder.crateApiApiSetupPush(
          config: config,
          identity: identity,
          state: snapshot,
          statePath: 'synthetic-no-account',
        ),
        throwsA(isA<_EncodedOnly>()),
      );
    }
    expect(
      snapshot.isDisposed,
      isFalse,
      reason:
          'a setup retry must borrow the saved snapshot, matching config and identity',
    );
    expect(
      snapshot.moveModes,
      [false, false],
      reason: 'each generated call must encode a borrowed snapshot',
    );
    expect(binding.dispatched, 2);
    expect(binding.allocations, isEmpty);
  });
}

