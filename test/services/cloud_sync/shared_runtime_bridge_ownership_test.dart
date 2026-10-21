// Exercise the real generated argument encoders, not a mock RustLibApi. Only
// the native allocator/dispatcher and opaque handles are synthetic. No library,
// account, device, network request or production state is opened by this test.
// ignore_for_file: subtype_of_sealed_class, implementation_imports, non_constant_identifier_names
import 'dart:ffi' as ffi;

import 'package:bluebubbles/src/rust/api/api.dart' as api;
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

class _Message extends Fake implements api.MessageInst {}

// Generated encoders cast to these implementation types. Recording move mode
// here detects actual generated ownership transfers without any native pointer.
class _Handle extends Fake
    implements
        JoinedOsConfigImpl,
        SenderImpl,
        ArcSenderPushMessageImpl,
        ArcAnisetteClientDefaultAnisetteProviderImpl,
        ApsConnectionImpl,
        ArcImClientImpl,
        ArcFtClientImpl,
        ArcIdmsAuthListenerImpl,
        ArcMutexVecActiveCircleSessionImpl,
        ArcMutexOptionCircleClientSessionDefaultAnisetteProviderImpl,
        ArcCloudMessagesClientDefaultAnisetteProviderImpl {
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

  // Message projection is independently tested. Keep this regression focused
  // on the generated state/client argument ownership before native dispatch.
  @override
  void sse_encode_box_autoadd_message_inst(
    api.MessageInst self,
    SseSerializer serializer,
  ) {}
}

void main() {
  const names = [
    'capture identity',
    'historical stage',
    'receive stage',
    'seal receive',
    'open receive seed',
    'notification setup',
  ];
  for (var index = 0; index < names.length; index++) {
    test(
      '${names[index]} borrows live handles across repeated bridge calls',
      () async {
        final binding = _Binding();
        addTearDown(binding.close);
        final encoder = _Encoder(binding);
        final handles = List.generate(12, (_) => _Handle());
        final state = api.SharedPushState(
          osConfig: handles[0],
          cancelPoll: handles[1],
          confDir: 'synthetic-no-account',
          localBroadcast: handles[2],
          anisette: handles[3],
          conn: handles[4],
          client: handles[5],
          ftClient: handles[6],
          idmsClient: handles[7],
          activeCircleSessions: handles[8],
          clientSession: handles[9],
        );
        const auth = api.CloudSyncNativeAuthMetadata(
          accountFingerprint: 'account',
          protectedStoreIdentity: 'store',
          nativeSessionId: 'session',
        );
        const seed = api.CloudSyncNativeReceivedArchiveSeed(
          accountFingerprint: 'account',
          protectedStoreIdentity: 'store',
          messageGuidHash: 'guid',
          sourceSha256: 'source',
          ciphertext: 'synthetic',
        );
        final operations = <(Function, TaskConstMeta, Map<Symbol, dynamic>)>[
          (
            encoder.crateApiApiCloudSyncCaptureReceivedIdentity,
            encoder.kCrateApiApiCloudSyncCaptureReceivedIdentityConstMeta,
            {},
          ),
          (
            encoder.crateApiApiCloudSyncStageHistoricalArchiveSource,
            encoder.kCrateApiApiCloudSyncStageHistoricalArchiveSourceConstMeta,
            {
              #expectedAuth: auth,
              #snapshotSha256: 'snapshot',
              #expectedSourceSha256: 'source',
              #sourceBytes: Uint8List.fromList([1]),
            },
          ),
          (
            encoder.crateApiApiCloudSyncStageReceivedArchiveSource,
            encoder.kCrateApiApiCloudSyncStageReceivedArchiveSourceConstMeta,
            {#expectedAuth: auth, #message: _Message()},
          ),
          (
            encoder.crateApiApiCloudSyncSealReceivedArchiveSeed,
            encoder.kCrateApiApiCloudSyncSealReceivedArchiveSeedConstMeta,
            {#expectedAuth: auth, #message: _Message()},
          ),
          (
            encoder.crateApiApiCloudSyncStageReceivedArchiveSeed,
            encoder.kCrateApiApiCloudSyncStageReceivedArchiveSeedConstMeta,
            {#expectedAuth: auth, #seed: seed},
          ),
          (
            encoder.crateApiApiCloudSyncConfigureMessagesChangeNotifications,
            encoder
                .kCrateApiApiCloudSyncConfigureMessagesChangeNotificationsConstMeta,
            {#expectedAuth: auth, #registrationNonce: 'nonce'},
          ),
        ];
        final (operation, metadata, extra) = operations[index];
        final arguments = <Symbol, dynamic>{...extra};
        // Also accepts the old signature so this test reproduces its actual
        // destructive serializer, rather than failing only at Dart compilation.
        if (metadata.argNames.contains('state')) {
          arguments[#state] = state;
        } else {
          arguments[#cloudMessagesClient] = handles[10];
          arguments[#storageDirectory] = state.confDir;
          if (metadata.argNames.contains('imClient'))
            arguments[#imClient] = state.client;
          if (metadata.argNames.contains('conn')) arguments[#conn] = state.conn;
        }
        for (var repeat = 0; repeat < 2; repeat++) {
          await expectLater(
            Function.apply(operation, [], arguments),
            throwsA(isA<_EncodedOnly>()),
          );
          expect(
            handles.any((handle) => handle.isDisposed),
            isFalse,
            reason:
                'a local CloudKit call must not consume messaging/login handles',
          );
        }
        expect(metadata.argNames, isNot(contains('state')));
        expect(binding.dispatched, 2);
        expect(binding.allocations, isEmpty);
      },
    );
  }
}
