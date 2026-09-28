import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_cursor_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_producer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot_codec.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Pure filesystem tests for the encrypted snapshot file. No ObjectBox
/// store is opened and no native bridge is touched: snapshots are built
/// from synthetic codec rows via fromEncodedRows, protection is an
/// in-memory scope/purpose-authenticating token fake, and the lease
/// transport is the local-exclusion fake from the cursor file tests.
String _t(String c) => List.filled(43, c).join();

CloudSyncHistoricalAccountBinding _account({String? fingerprint}) =>
    CloudSyncHistoricalAccountBinding(
      accountFingerprint: fingerprint ?? _t('A'),
      protectedStoreIdentity: 'obcs2.store.${_t('S')}',
    );

CloudSyncHistoricalChatView _chat() => const CloudSyncHistoricalChatView(
  id: 11,
  guid: 'iMessage;-;peer@example.com',
  style: 45,
  chatIdentifier: 'peer@example.com',
  isRoutingStub: false,
  dateDeletedPresent: false,
  isRpSms: false,
  participantCount: 1,
  participantAddress: 'peer@example.com',
  participantService: 'iMessage',
);

String _row(int id, {String? text}) {
  final body = text ?? 'snapshot row $id alpha';
  return encodeHistoricalSnapshotRow(
    CloudSyncHistoricalRowView(
      guid: 'snap-row-$id',
      text: body,
      attributedBodies: [AttributedBody.raw(body)],
      hasActualEditOrUnsend: false,
      dateEditedPresent: false,
      associationPresent: false,
      isFromMe: false,
      senderAddress: 'peer@example.com',
      chat: _chat(),
      dateCreatedMs: 1700000000000,
      error: 0,
      isTemp: false,
      stagingGuid: null,
      sendingServiceId: null,
      hasBeenForwarded: false,
      verificationFailed: false,
      ckRecordId: null,
      ckSyncState: false,
      messageId: id,
      itemType: 0,
      groupActionType: 0,
      groupTitle: null,
      isDeleted: false,
      dateScheduledPresent: false,
      threadOriginatorPresent: false,
      hasAttachments: false,
      attachmentCount: 0,
      subjectPresent: false,
      expressiveSendStyleIdPresent: false,
      balloonBundleIdPresent: false,
      payloadDataPresent: false,
      hasApplePayloadData: false,
      amkSessionIdPresent: false,
      rowSnapshotSha256: '0' * 64,
    ),
  );
}

CloudSyncHistoricalSnapshot _snapshot(List<String> rows) =>
    CloudSyncHistoricalSnapshot.fromEncodedRows(
      encodedRows: rows,
      account: _account(),
      accountHandles: const ['me@example.com'],
      capturedAtMs: DateTime.now().millisecondsSinceEpoch,
    );

/// In-memory token keyring. Ciphertexts are opaque counter tokens whose
/// (scope, purpose, store, plaintext) entries live only in this shared
/// memory map; nothing is encoded into the token itself, so a substituted
/// or tampered token simply misses the map. Reopened file instances reuse
/// the same fake/keyring. This exercises the persistence protocol, never
/// real encryption proof.
final class _TokenProtector implements CloudSyncProtector {
  _TokenProtector({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    Map<String, ({String scopeKey, String kind, String store, String plain})>?
    keyring,
  }) : keyring = keyring ?? {};

  final String accountFingerprint;
  final String protectedStoreIdentity;
  final List<String> calls = [];
  Future<void> Function()? onProtect;
  Future<void> Function()? onUnprotect;
  final Map<
    String,
    ({String scopeKey, String kind, String store, String plain})
  >
  keyring;
  int _nextToken = 0;
  String? _storageKey;

  void _check(CloudSyncScope scope, CloudSyncProtectedValueKind kind) {
    if (kind != CloudSyncProtectedValueKind.historicalSnapshot ||
        scope.accountFingerprint != accountFingerprint) {
      throw StateError('token scope mismatch');
    }
    // CloudSyncScope carries no store-identity field; bind the stable
    // storage key across calls so a substituted scope cannot pass.
    _storageKey ??= scope.storageKey;
    if (scope.storageKey != _storageKey) {
      throw StateError('token scope mismatch');
    }
  }

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async {
    calls.add('${kind.name}:${scope.storageKey}');
    _check(scope, kind);
    await onProtect?.call();
    final token = 'tok1.${_nextToken++}';
    keyring[token] = (
      scopeKey: scope.storageKey,
      kind: kind.name,
      store: protectedStoreIdentity,
      plain: plaintext,
    );
    return token;
  }

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    _check(scope, kind);
    final entry = keyring[ciphertext];
    if (entry == null ||
        entry.kind != kind.name ||
        entry.scopeKey != scope.storageKey ||
        entry.store != protectedStoreIdentity) {
      throw StateError('token mismatch');
    }
    await onUnprotect?.call();
    return entry.plain;
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) =>
      throw StateError('unused');
}

class _BaseTransport implements CloudProtectedPageLeaseTransport {
  @override
  String get protectedPageLeaseRecoveryIdentity => 'obcs2.store.${_t('S')}';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_transport_access');
}

// Local exclusion only; never the native cross-process lock.
class _LocalTransport extends _BaseTransport
    implements CloudProtectedLocalLifecycleTransport {
  String identity = 'obcs2.store.${_t('S')}';
  int entries = 0;
  @override
  String get protectedPageLeaseRecoveryIdentity => identity;
  @override
  Future<T> runLocalProtectedStoreExclusive<T>(
    Future<T> Function() action,
  ) async {
    entries++;
    return action();
  }
}

void main() {
  late Directory directory;
  late _TokenProtector protector;
  late _LocalTransport transport;
  late int stillCurrentCalls;
  late bool Function() stillCurrent;
  late Future<void> Function() validateIdentity;

  CloudSyncHistoricalSnapshotFile file({
    CloudSyncHistoricalAccountBinding? account,
    CloudSyncProtector? protectorOverride,
    CloudProtectedPageLeaseTransport? transportOverride,
    String? sourceIdentity,
  }) => CloudSyncHistoricalSnapshotFile(
    privateStorageDirectory: directory.path,
    account: account ?? _account(),
    sourceIdentitySha256: sourceIdentity,
    protector: protectorOverride ?? protector,
    transport: transportOverride ?? transport,
    validateIdentity: validateIdentity,
    stillCurrent: stillCurrent,
  );

  File snapshotFile() {
    final folder = Directory(
      '${directory.path}/cloud-sync-v2-history-snapshots',
    );
    final matches = folder
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.snapshot'))
        .toList();
    expect(matches, hasLength(1));
    return matches.single;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ob-history-snapshot-');
    protector = _TokenProtector(
      accountFingerprint: _t('A'),
      protectedStoreIdentity: 'obcs2.store.${_t('S')}',
    );
    transport = _LocalTransport();
    stillCurrentCalls = 0;
    stillCurrent = () {
      stillCurrentCalls++;
      return true;
    };
    validateIdentity = () async {};
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('save then load reopens the exact snapshot, rows and cursor', () async {
    final snapshot = _snapshot([for (var i = 1; i <= 3; i++) _row(i)]);
    await file().save(snapshot);
    final reopened = file();
    final loaded = (await reopened.load())!;
    expect(loaded.manifest.snapshotSha256, snapshot.manifest.snapshotSha256);
    expect(loaded.manifest.messageCount, 3);
    expect(loaded.encodedByteLength, snapshot.encodedByteLength);
    expect(loaded.manifest.accountHandles, ['me@example.com']);
    expect(loaded.encodedRows.toList(), snapshot.encodedRows.toList());
    String? cursor;
    final seen = <String>[];
    do {
      final page = await loaded.readPage(cursor: cursor, limit: 2);
      seen.addAll([for (final view in page.views) view.guid]);
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(seen, ['snap-row-1', 'snap-row-2', 'snap-row-3']);
    expect(transport.entries, greaterThan(0));
  });

  test('load without a save returns null', () async {
    expect(await file().load(), isNull);
  });

  test('reopened archive cursor resumes the same retained source', () async {
    final original = _snapshot([for (var i = 1; i <= 3; i++) _row(i)]);
    await file().save(original);
    CloudSyncHistoricalCursorFile cursorFor(
      CloudSyncHistoricalSnapshot source,
    ) => CloudSyncHistoricalCursorFile(
      privateStorageDirectory: directory.path,
      manifest: source.manifest,
      account: _account(),
      transport: transport,
      stillCurrent: stillCurrent,
      mode: CloudSyncHistoricalCursorMode.archive,
    );
    final firstPage = await original.readPage(limit: 2);
    final cursors = cursorFor(original);
    expect(await cursors.load(), isNull);
    await cursors.save(
      HistoricalProducerCursor(
        scope: original.scope,
        lastId: firstPage.nextCursor,
        done: false,
      ),
    );
    final reopened = (await file().load())!;
    final checkpoint = (await cursorFor(reopened).load())!;
    final nextPage = await reopened.readPage(
      cursor: checkpoint.lastId,
      limit: 2,
    );
    expect(checkpoint.done, isFalse);
    expect(nextPage.views.map((row) => row.guid), ['snap-row-3']);
    expect(nextPage.nextCursor, isNull);
    // A successful read alone never advances or completes the stored cursor.
    expect((await cursorFor(reopened).load())!.lastId, firstPage.nextCursor);
  });

  test('stored files exclude plaintext and authenticate purpose', () async {
    final snapshot = _snapshot([_row(1, text: 'Shannon entropy probe 9xQ2')]);
    await file().save(snapshot);
    final raw = await snapshotFile().readAsString();
    expect(raw.contains('Shannon entropy probe 9xQ2'), isFalse);
    expect(raw.contains('peer@example.com'), isFalse);
    expect(raw.contains('me@example.com'), isFalse);
    expect(protector.calls, isNotEmpty);
    expect(
      protector.calls.every((c) => c.startsWith('historicalSnapshot:')),
      isTrue,
    );
  });

  test('existing snapshot is preserved when saving a different one', () async {
    final first = _snapshot([_row(1)]);
    final other = _snapshot([_row(1, text: 'divergent row one')]);
    expect(other.manifest.snapshotSha256, isNot(first.manifest.snapshotSha256));
    await file().save(first);
    await expectLater(
      file().save(other),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_snapshot_already_present',
        ),
      ),
    );
    final loaded = (await file().load())!;
    expect(loaded.manifest.snapshotSha256, first.manifest.snapshotSha256);
    expect(loaded.encodedRows.toList(), first.encodedRows.toList());
    await file().save(first);
    expect(
      (await file().load())!.manifest.snapshotSha256,
      first.manifest.snapshotSha256,
    );
  });

  test(
    'truncated, flipped, reordered and substituted files are rejected',
    () async {
      // 205 rows force two sealed chunks (200-row page cap).
      final snapshot = _snapshot([for (var i = 1; i <= 205; i++) _row(i)]);
      await file().save(snapshot);
      final target = snapshotFile();
      final raw = await target.readAsString();
      Future<void> expectRejected(String candidate) async {
        await target.writeAsString(candidate, flush: true);
        await expectLater(file().load(), throwsStateError);
        // Corrupted bytes are retained exactly, never deleted or repaired.
        expect(await target.readAsString(), candidate);
      }

      await expectRejected(raw.substring(0, raw.length - 100));
      expect(raw.length, greaterThan(100));
      final flipAt = raw.length ~/ 2;
      final flipped = raw.replaceRange(
        flipAt,
        flipAt + 1,
        raw[flipAt] == 'A' ? 'B' : 'A',
      );
      await expectRejected(flipped);
      final envelope = List<dynamic>.of(jsonDecode(raw) as List);
      final chunks = List<dynamic>.of(envelope[3] as List);
      expect(chunks.length, greaterThan(1));
      // A true reorder keeps the entry count and leaves the original list
      // intact for the substitution step below.
      final reordered = List<dynamic>.of(envelope)
        ..[3] = chunks.reversed.toList();
      expect((reordered[3] as List).length, chunks.length);
      expect(chunks.length, greaterThan(1));
      await expectRejected(jsonEncode(reordered));
      final other = _snapshot([_row(1, text: 'foreign chunk row')]);
      final otherDir = await Directory.systemTemp.createTemp(
        'ob-history-other-',
      );
      try {
        final otherFile = CloudSyncHistoricalSnapshotFile(
          privateStorageDirectory: otherDir.path,
          account: _account(),
          protector: protector,
          transport: transport,
          validateIdentity: validateIdentity,
          stillCurrent: stillCurrent,
        );
        await otherFile.save(other);
        final otherRaw = await otherDir
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((f) => f.path.endsWith('.snapshot'))
            .readAsString();
        final otherChunks = (jsonDecode(otherRaw) as List)[3] as List;
        final substituted = List<dynamic>.of(envelope)
          ..[3] = ([otherChunks.first, ...chunks.skip(1)]);
        await expectRejected(jsonEncode(substituted));
      } finally {
        await otherDir.delete(recursive: true);
      }
      await target.writeAsString(raw, flush: true);
      expect(
        (await file().load())!.manifest.snapshotSha256,
        snapshot.manifest.snapshotSha256,
      );
    },
  );

  test('forged header seal is rejected even with valid chunks', () async {
    final snapshot = _snapshot([_row(1)]);
    await file().save(snapshot);
    final target = snapshotFile();
    final envelope = List<dynamic>.of(
      jsonDecode(await target.readAsString()) as List,
    );
    final forged = await protector.protect(
      scope: CloudSyncScope(
        accountFingerprint: _t('A'),
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'messageManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      ),
      kind: CloudSyncProtectedValueKind.historicalSnapshot,
      plaintext: jsonEncode([
        1,
        'f' * 64,
        _t('A'),
        'obcs2.store.${_t('S')}',
        ['me@example.com'],
        1,
        snapshot.manifest.capturedAtMs,
        snapshot.encodedByteLength,
        1,
      ]),
    );
    envelope[2] = forged;
    await target.writeAsString(jsonEncode(envelope), flush: true);
    await expectLater(file().load(), throwsStateError);
  });

  test('substituted and tampered tokens miss the keyring', () async {
    final snapshot = _snapshot([_row(1)]);
    await file().save(snapshot);
    final target = snapshotFile();
    final raw = await target.readAsString();
    Future<void> expectRejected(String candidate) async {
      await target.writeAsString(candidate, flush: true);
      await expectLater(file().load(), throwsStateError);
      expect(await target.exists(), isTrue);
    }

    final envelope = List<dynamic>.of(jsonDecode(raw) as List);
    final headerToken = envelope[2] as String;
    final unknown = List<dynamic>.of(envelope)..[2] = 'tok1.999999';
    await expectRejected(jsonEncode(unknown));
    final tampered = List<dynamic>.of(envelope)..[2] = '${headerToken}z';
    await expectRejected(jsonEncode(tampered));
    final chunks = List<dynamic>.of(envelope[3] as List);
    final swapped = List<dynamic>.of(envelope)
      ..[3] = ([headerToken, ...chunks.skip(1)]);
    await expectRejected(jsonEncode(swapped));
    await target.writeAsString(raw, flush: true);
    expect(
      (await file().load())!.manifest.snapshotSha256,
      snapshot.manifest.snapshotSha256,
    );
  });

  test('sealed entries do not move across store bindings', () async {
    CloudSyncScope scope() => CloudSyncScope(
      accountFingerprint: _t('A'),
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'messageManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final sealed = await protector.protect(
      scope: scope(),
      kind: CloudSyncProtectedValueKind.historicalSnapshot,
      plaintext: 'sealed payload',
    );
    expect(
      await protector.unprotect(
        scope: scope(),
        kind: CloudSyncProtectedValueKind.historicalSnapshot,
        ciphertext: sealed,
      ),
      'sealed payload',
    );
    await expectLater(
      protector.unprotect(
        scope: scope(),
        kind: CloudSyncProtectedValueKind.historicalSnapshot,
        ciphertext: 'tok1.999999',
      ),
      throwsStateError,
    );
    final foreign = _TokenProtector(
      accountFingerprint: _t('A'),
      protectedStoreIdentity: 'obcs2.store.${_t('Z')}',
      keyring: protector.keyring,
    );
    await expectLater(
      foreign.unprotect(
        scope: scope(),
        kind: CloudSyncProtectedValueKind.historicalSnapshot,
        ciphertext: sealed,
      ),
      throwsStateError,
    );
  });

  test(
    'identity changes fail initial save validation and read entry',
    () async {
      final snapshot = _snapshot([_row(1)]);
      stillCurrent = () {
        stillCurrentCalls++;
        return stillCurrentCalls < 3;
      };
      await expectLater(
        file().save(snapshot),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloud_sync_historical_snapshot_identity_changed',
          ),
        ),
      );
      stillCurrentCalls = 0;
      stillCurrent = () => true;
      await file().save(snapshot);
      stillCurrent = () => false;
      await expectLater(
        file().load(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloud_sync_historical_snapshot_identity_changed',
          ),
        ),
      );
      stillCurrent = () => true;
      transport.identity = 'obcs2.store.${_t('Z')}';
      await expectLater(
        file().load(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloud_sync_historical_snapshot_identity_changed',
          ),
        ),
      );
    },
  );

  test('identity loss after unprotect begins fails the read', () async {
    final snapshot = _snapshot([_row(1)]);
    await file().save(snapshot);
    // Flip currency only once a sealed value has genuinely been opened:
    // the post-unprotect identity check must fail the read.
    // The file captures the closure below, so the hook flips the shared
    // flag it reads rather than replacing the closure itself.
    var current = true;
    stillCurrent = () => current;
    var opened = 0;
    protector.onUnprotect = () async {
      opened++;
      current = false;
    };
    await expectLater(
      file().load(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_snapshot_identity_changed',
        ),
      ),
    );
    expect(opened, greaterThan(0));
  });

  test('save failing after temp creation cleans the temp file', () async {
    final snapshot = _snapshot([_row(1)]);
    // Fail validation only once the generated temp file is observable,
    // proving the failure lands inside the write-finalize window.
    var observedTmp = false;
    validateIdentity = () async {
      final tmps = directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      if (tmps.isNotEmpty) {
        observedTmp = true;
        throw StateError('cloud_sync_historical_snapshot_identity_changed');
      }
    };
    await expectLater(
      file().save(snapshot),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_snapshot_identity_changed',
        ),
      ),
    );
    expect(observedTmp, isTrue);
    expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
    validateIdentity = () async {};
    await file().save(snapshot);
    expect(
      (await file().load())!.manifest.snapshotSha256,
      snapshot.manifest.snapshotSha256,
    );
  });

  test('protector bound to another account cannot save', () async {
    final foreign = _TokenProtector(
      accountFingerprint: _t('Z'),
      protectedStoreIdentity: 'obcs2.store.${_t('S')}',
    );
    await expectLater(
      file(protectorOverride: foreign).save(_snapshot([_row(1)])),
      throwsStateError,
    );
    expect(
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.snapshot'))
          .toList(),
      isEmpty,
    );
  });

  test('interrupted save leaves no partial snapshot and retry works', () async {
    final snapshot = _snapshot([_row(1)]);
    var seals = 0;
    protector.onProtect = () async {
      if (++seals == 2) throw StateError('synthetic mid-save failure');
    };
    await expectLater(file().save(snapshot), throwsStateError);
    final leftovers = directory
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    expect(leftovers.where((f) => f.path.endsWith('.snapshot')), isEmpty);
    expect(leftovers.where((f) => f.path.endsWith('.tmp')), isEmpty);
    protector.onProtect = null;
    await file().save(snapshot);
    expect(
      (await file().load())!.manifest.snapshotSha256,
      snapshot.manifest.snapshotSha256,
    );
  });

  test('protector exceptions cannot disclose captured content', () async {
    const privateText = 'synthetic private content must not appear';
    final snapshot = _snapshot([_row(1, text: privateText)]);
    protector.onProtect = () async => throw StateError(privateText);
    await expectLater(
      file().save(snapshot),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'reason',
          'cloud_sync_historical_snapshot_protection_unavailable',
        ),
      ),
    );
    protector.onProtect = null;
    await file().save(snapshot);
    final before = await snapshotFile().readAsBytes();
    protector.onUnprotect = () async => throw StateError(privateText);
    await expectLater(
      file().load(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'reason',
          'cloud_sync_historical_snapshot_unprotect_failed',
        ),
      ),
    );
    expect(await snapshotFile().readAsBytes(), before);
  });

  test(
    'orphan files are retained while foreign entries are rejected',
    () async {
      final snapshots = Directory(
        '${directory.path}/cloud-sync-v2-history-snapshots',
      );
      await snapshots.create(recursive: true);
      final orphan = File('${snapshots.path}/orphan.tmp');
      await orphan.writeAsString('leftover', flush: true);
      final snapshot = _snapshot([_row(1)]);
      await file().save(snapshot);
      expect(await orphan.exists(), isTrue);
      expect(
        (await file().load())!.manifest.snapshotSha256,
        snapshot.manifest.snapshotSha256,
      );
    },
  );

  test('foreign directory entries inside the folder are rejected', () async {
    final snapshots = Directory(
      '${directory.path}/cloud-sync-v2-history-snapshots',
    );
    await snapshots.create(recursive: true);
    await Directory('${snapshots.path}/nested').create();
    await expectLater(
      file().save(_snapshot([_row(1)])),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_snapshot_storage_untrusted',
        ),
      ),
    );
  });

  test('unavailable native local exclusion fails save and load', () async {
    final direct = _BaseTransport();
    await expectLater(
      file(transportOverride: direct).save(_snapshot([_row(1)])),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_snapshot_exclusion_unavailable',
        ),
      ),
    );
    await expectLater(
      file(transportOverride: direct).load(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_snapshot_exclusion_unavailable',
        ),
      ),
    );
  });

  test('account isolation keeps separate snapshot files', () async {
    final snapshot = _snapshot([_row(1)]);
    await file().save(snapshot);
    final other = file(account: _account(fingerprint: _t('Z')));
    expect(await other.load(), isNull);
    await expectLater(
      other.save(snapshot),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_historical_snapshot_binding_invalid',
        ),
      ),
    );
    final files = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.snapshot'))
        .toList();
    expect(files, hasLength(1));
  });

  test(
    'multi-chunk snapshot pages transparently across chunk bounds',
    () async {
      final rows = [for (var i = 1; i <= 250; i++) _row(i)];
      final snapshot = _snapshot(rows);
      await file().save(snapshot);
      final loaded = (await file().load())!;
      expect(loaded.manifest.messageCount, 250);
      expect(loaded.encodedRows.toList(), rows);
      final seen = <int>[];
      String? cursor;
      do {
        final page = await loaded.readPage(cursor: cursor, limit: 200);
        seen.addAll([
          for (final view in page.views)
            int.parse(view.guid.substring('snap-row-'.length)),
        ]);
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(seen, [for (var i = 1; i <= 250; i++) i]);
    },
  );

  test('default slot preserves the exact legacy v1 file name', () async {
    final snapshot = _snapshot([_row(1)]);
    await file().save(snapshot);
    final legacyKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-historical-snapshot-file-v1',
              _t('A'),
              'obcs2.store.${_t('S')}',
            ]),
          ),
        )
        .toString();
    final target = snapshotFile();
    expect(target.path.endsWith('$legacyKey.snapshot'), isTrue);
    expect(
      (await file().load())!.manifest.snapshotSha256,
      snapshot.manifest.snapshotSha256,
    );
  });

  test('two source slots stay isolated under one account and store', () async {
    final alpha = _snapshot([_row(1)]);
    final live = _snapshot([_row(1, text: 'divergent live row')]);
    expect(live.manifest.snapshotSha256, isNot(alpha.manifest.snapshotSha256));
    await file(sourceIdentity: 'a' * 64).save(alpha);
    await file(sourceIdentity: 'b' * 64).save(live);
    final files = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.snapshot'))
        .toList();
    expect(files, hasLength(2));
    final reloadedAlpha = (await file(sourceIdentity: 'a' * 64).load())!;
    final reloadedLive = (await file(sourceIdentity: 'b' * 64).load())!;
    expect(
      reloadedAlpha.manifest.snapshotSha256,
      alpha.manifest.snapshotSha256,
    );
    expect(reloadedLive.manifest.snapshotSha256, live.manifest.snapshotSha256);
    expect(reloadedAlpha.encodedRows.toList(), alpha.encodedRows.toList());
    expect(reloadedLive.encodedRows.toList(), live.encodedRows.toList());
  });

  test(
    'transplanted slot file is rejected while the donor still loads',
    () async {
      final alpha = _snapshot([_row(1)]);
      final live = _snapshot([_row(1, text: 'divergent live row')]);
      await file(sourceIdentity: 'a' * 64).save(alpha);
      final alphaPath = snapshotFile().path;
      await file(sourceIdentity: 'b' * 64).save(live);
      final livePath = directory
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (f) => f.path.endsWith('.snapshot') && !p.equals(f.path, alphaPath),
          )
          .single
          .path;
      final destinationEnvelope =
          jsonDecode(await File(livePath).readAsString()) as List;
      // Copy slot A bytes over slot B: outer key and sealed slot disagree.
      await File(
        livePath,
      ).writeAsBytes(await File(alphaPath).readAsBytes(), flush: true);
      await expectLater(
        file(sourceIdentity: 'b' * 64).load(),
        throwsStateError,
      );
      // Fixing the public outer key must not bypass the sealed source binding.
      final transplanted =
          jsonDecode(await File(alphaPath).readAsString()) as List;
      transplanted[1] = destinationEnvelope[1];
      await File(livePath).writeAsString(jsonEncode(transplanted), flush: true);
      await expectLater(
        file(sourceIdentity: 'b' * 64).load(),
        throwsStateError,
      );
      expect(
        (await file(sourceIdentity: 'a' * 64).load())!.manifest.snapshotSha256,
        alpha.manifest.snapshotSha256,
      );
    },
  );

  test('invalid source identities are rejected at construction', () {
    for (final bad in ['ZZZ', 'A' * 64, 'a' * 63, 'a' * 65, '']) {
      expect(
        () => file(sourceIdentity: bad),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloud_sync_historical_snapshot_binding_invalid',
          ),
        ),
      );
    }
  });

  test('repeated same-source reopening returns identical snapshots', () async {
    final snapshot = _snapshot([_row(1)]);
    await file(sourceIdentity: 'a' * 64).save(snapshot);
    for (var i = 0; i < 2; i++) {
      final loaded = (await file(sourceIdentity: 'a' * 64).load())!;
      expect(loaded.manifest.snapshotSha256, snapshot.manifest.snapshotSha256);
      expect(loaded.encodedRows.toList(), snapshot.encodedRows.toList());
    }
  });
}
