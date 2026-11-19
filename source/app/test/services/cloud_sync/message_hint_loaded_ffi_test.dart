import 'dart:io';
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

// Explicit isolated DLL only. No fallback to an installed application library.
void main() {
  if (Platform.environment['RUN_MESSAGE_HINT_FFI'] != '1') {
    test('Loaded Message hint FFI qualification is explicitly opt-in', () {},
      skip: 'Set RUN_MESSAGE_HINT_FFI=1 with the pinned isolated DLL and synthetic fixture.');
    return;
  }
  setUpAll(() async {
    final path = Platform.environment['MESSAGE_HINT_FFI_DLL'];
    final expected = Platform.environment['MESSAGE_HINT_FFI_SHA256'];
    final fixture = Platform.environment['MESSAGE_HINT_FFI_FIXTURE_DIR'];
    expect(path, isNotNull, reason: 'Opt-in requires an explicit isolated DLL');
    expect(path, isNotEmpty);
    expect(expected, matches(RegExp(r'^[0-9a-f]{64}$')),
      reason: 'Opt-in requires the exact DLL SHA256');
    expect(fixture, isNotNull, reason: 'Opt-in requires the synthetic fixture');
    expect(fixture, isNotEmpty);
    expect(await File('$fixture/message-hint-fixture.json').exists(), isTrue);
    expect(sha256.convert(await File(path!).readAsBytes()).toString(), expected);
    await RustLib.init(externalLibrary: ExternalLibrary.open(path));
    // init checks the exported native hash against this generated Dart hash.
    expect(RustLib.instance.rustContentHash, -1363362104);
  });
  tearDownAll(RustLib.dispose);

  test('Loaded FFI recovery and GC preserve empty hints and reject unverifiable roots', () async {
    final directory = await Directory.systemTemp.createTemp('message-hint-ffi-');
    addTearDown(() => directory.delete(recursive: true));
    final adapter = FrbNativeProtectedCloudSyncBindings();
    final root = CloudProtectedMessageSourceRootHint(
      rawReference: 'obcs2.ref.${'A' * 43}', accountFingerprint: 'B' * 43,
      generation: 9007199254740993,
    );
    for (final roots in [<CloudProtectedMessageSourceRootHint>[], [root]]) {
      final recovery = await adapter.recoverWithMessageSourceRoots(
        storageDirectory: directory.path, adoptedLeaseReferences: const [],
        liveReferences: [root.rawReference], liveReferenceEnumerationComplete: true,
        messageSourceRoots: roots);
      final gc = await adapter.collectWithMessageSourceRoots(
        storageDirectory: directory.path, liveReferences: [root.rawReference],
        liveReferenceEnumerationComplete: true, messageSourceRoots: roots);
      expect(recovery.failure == null, roots.isEmpty);
      expect(gc.failure == null, roots.isEmpty);
      expect(recovery.recovery != null, roots.isEmpty);
      expect(gc.collection != null, roots.isEmpty);
    }
    expect(await directory.list().isEmpty, isTrue);
  });

  test('Synthetic ObjectBox reopen lifecycle reaches loaded native recovery and GC', () async {
    final directory = await Directory.systemTemp.createTemp('message-hint-lifecycle-');
    final nativeDirectory = await Directory('${directory.path}/native').create();
    var box = await openStore(directory: '${directory.path}/db');
    addTearDown(() async { box.close(); await directory.delete(recursive: true); });
    ObjectBoxCloudSyncStore makeStore() => ObjectBoxCloudSyncStore(
      store: box, protector: _UnusedProtector());
    var store = makeStore();
    final transport = NativeProtectedCloudSyncTransport(
      cloudMessagesClient: Object(), storageDirectory: nativeDirectory.path,
      protectedStoreIdentity: 'obcs2.store.${'C' * 43}',
      bindings: FrbNativeProtectedCloudSyncBindings());
    CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests();
    addTearDown(CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests);
    var lifecycle = CloudProtectedPageLeaseLifecycle(store: store, transport: transport);
    await lifecycle.ensureRecoveredBeforeWrite();
    await lifecycle.collectOneProtectedGarbagePage();

    final scope = CloudSyncScope(accountFingerprint: 'B' * 43,
      container: 'com.apple.messages.cloud', database: 'private', zone: 'messageManateeZone',
      streamKind: CloudSyncStreamKind.messages, schemaVersion: 2,
      persistenceLane: CloudSyncPersistenceLane.semantic);
    final raw = 'obcs2.ref.${'A' * 43}';
    await store.upsertRecordMap(CloudRecordMapEntry(scope: scope,
      logicalEntityKeyHash: '${'A' * 41}-_', serverRecordIdHash: '${'B' * 41}_-',
      encryptedServerRecordId: 'obcs2.ref.${'D' * 43}', generation: 1,
      encryptedRawRecordReference: raw, rawRecordGeneration: 1,
      updatedAt: DateTime.utc(2026, 11, 16)), generation: 1);
    box.close();
    box = await openStore(directory: '${directory.path}/db');
    store = makeStore();
    final snapshot = await store.readLiveProtectedReferences(maximumCount: 32);
    expect(snapshot.isComplete, isTrue);
    expect(snapshot.messageSourceRoots, hasLength(1));
    expect(snapshot.messageSourceRoots.single.rawReference, raw);
    expect(snapshot.messageSourceRoots.single.accountFingerprint, scope.accountFingerprint);
    lifecycle = CloudProtectedPageLeaseLifecycle(store: store, transport: transport);
    final rejected = throwsA(isA<CloudSyncFailure>().having(
      (failure) => failure.category, 'category', CloudFailureCategory.localStorage));
    await expectLater(lifecycle.ensureRecoveredBeforeWrite(), rejected);
    await expectLater(lifecycle.collectOneProtectedGarbagePage(), rejected);
    expect((await store.readLiveProtectedReferences(maximumCount: 32)).messageSourceRoots,
      hasLength(1));
    expect(box.box<CloudRecordMapEntity>().count(), 1);
  });

  test('Loaded FFI lifecycle preserves verified synthetic source receipt after ObjectBox reopen', () async {
    final fixturePath = Platform.environment['MESSAGE_HINT_FFI_FIXTURE_DIR'];
    expect(fixturePath, isNotNull);
    final fixture = Directory(fixturePath!);
    final manifest = jsonDecode(await File('${fixture.path}/message-hint-fixture.json').readAsString())
      as Map<String, dynamic>;
    expect(manifest['kind'], 'synthetic-message-hint-ffi-fixture');
    final raw = manifest['rawReference'] as String;
    final receipt = File('${fixture.path}/${manifest['receiptRelativePath']}');
    final rawFile = File('${fixture.path}/${manifest['rawRelativePath']}');
    final receiptDigest = sha256.convert(await receipt.readAsBytes());
    final rawDigest = sha256.convert(await rawFile.readAsBytes());
    final directory = await Directory.systemTemp.createTemp('verified-hint-db-');
    var box = await openStore(directory: directory.path);
    addTearDown(() async { box.close(); await directory.delete(recursive: true); });
    ObjectBoxCloudSyncStore makeStore() => ObjectBoxCloudSyncStore(
      store: box, protector: _UnusedProtector());
    var store = makeStore();
    final scope = CloudSyncScope(accountFingerprint: manifest['accountFingerprint'] as String,
      container: 'com.apple.messages.cloud', database: 'private', zone: 'messageManateeZone',
      streamKind: CloudSyncStreamKind.messages, schemaVersion: 2,
      persistenceLane: CloudSyncPersistenceLane.semantic);
    for (var i = 1; i < 7; i++) {
      await store.advanceOutboxGeneration(scope, now: DateTime.utc(2026, 11, 16));
    }
    expect((await store.readCheckpoint(scope)).generation, 7);
    await store.upsertRecordMap(CloudRecordMapEntry(scope: scope,
      logicalEntityKeyHash: '${'A' * 41}-_', serverRecordIdHash: '${'B' * 41}_-',
      // Synthetic metadata placeholder, not used by maintenance validation.
      encryptedServerRecordId: 'fixture-server-id', generation: 7,
      encryptedRawRecordReference: raw, rawRecordGeneration: 7,
      updatedAt: DateTime.utc(2026, 11, 16)), generation: 7);
    box.close();
    box = await openStore(directory: directory.path);
    store = makeStore();
    final snapshot = await store.readLiveProtectedReferences(maximumCount: 32);
    expect(snapshot.isComplete, isTrue);
    expect(snapshot.messageSourceRoots.single.generation, manifest['generation']);
    final transport = NativeProtectedCloudSyncTransport(cloudMessagesClient: Object(),
      storageDirectory: fixture.path, protectedStoreIdentity: 'obcs2.store.${'E' * 43}',
      bindings: FrbNativeProtectedCloudSyncBindings());
    CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests();
    addTearDown(CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests);
    final lifecycle = CloudProtectedPageLeaseLifecycle(store: store, transport: transport);
    await lifecycle.ensureRecoveredBeforeWrite();
    await lifecycle.collectOneProtectedGarbagePage();
    expect(sha256.convert(await receipt.readAsBytes()).toString(), receiptDigest.toString());
    expect(sha256.convert(await rawFile.readAsBytes()).toString(), rawDigest.toString());
    expect(box.box<CloudRecordMapEntity>().count(), 1);
  });
}

class _UnusedProtector implements CloudSyncProtector {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
    throw StateError('Synthetic metadata test must not access secret storage');
}
