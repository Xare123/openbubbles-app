import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_historical_source.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_source.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Filesystem and contract tests for the Windows Alpha source capture.
///
/// Pure negative paths run anywhere. The real-DB success case needs a
/// working native ObjectBox library, which this host blocks (Application
/// Control 4551); it is authored for the qualified runner and reported
/// as blocked here, never bypassed or claimed executed.
String _t(String c) => List.filled(43, c).join();

Future<Directory> _sourceDirectory({
  required Directory parent,
  required List<int> databaseBytes,
  required Map<String, Object?> qualification,
}) async {
  final source = await parent.createTemp('alpha-evidence-');
  await File(
    '${source.path}/data.mdb',
  ).writeAsBytes(databaseBytes, flush: true);
  await File(
    '${source.path}/capture-qualification.json',
  ).writeAsString(jsonEncode(qualification), flush: true);
  return source;
}

Map<String, Object?> _qualification({
  required String digest,
  required int bytes,
}) => {
  'stable': true,
  'package': 'com.bluebubbles.messaging.alpha',
  'bytes': bytes,
  'databaseSha256': digest,
  'remoteBeforeSha256': digest,
  'remoteAfterSha256': digest,
};

void main() {
  late Directory root;
  late Directory scratch;

  CloudSyncHistoricalAccountBinding account() =>
      CloudSyncHistoricalAccountBinding(
        accountFingerprint: _t('A'),
        protectedStoreIdentity: 'obcs2.store.${_t('S')}',
      );

  Future<CloudSyncHistoricalImportSource> capture({
    required Directory source,
    required String digest,
    String label = 'Alpha history',
    bool Function()? stillCurrent,
    Future<void> Function()? validateIdentity,
  }) => captureCloudSyncWindowsHistoricalSource(
    sourceDirectory: source,
    scratchRoot: scratch,
    expectedDatabaseSha256: digest,
    account: account(),
    accountHandles: const ['owner@example.com'],
    label: label,
    capturedAtMs: DateTime.now().millisecondsSinceEpoch,
    validateIdentity: validateIdentity ?? () async {},
    stillCurrent: stillCurrent ?? () => true,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ob-windows-source-');
    scratch = await Directory('${root.path}/scratch').create();
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test(
    'malformed expected digests are rejected without touching disk',
    () async {
      for (final bad in ['ZZZ', 'A' * 64, 'a' * 63, 'a' * 65, '']) {
        await expectLater(
          capture(source: Directory('${root.path}/missing'), digest: bad),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'cloud_sync_windows_historical_source_invalid',
            ),
          ),
        );
      }
    },
  );

  test('invalid labels fail before evidence is touched', () async {
    for (final bad in ['', '  ', 'x' * 121, 'line\nbreak', 'nul\u0000']) {
      await expectLater(
        capture(
          source: Directory('${root.path}/missing'),
          digest: 'a' * 64,
          label: bad,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloud_sync_historical_import_source_invalid',
          ),
        ),
      );
    }
  });

  test('missing source layout is unavailable', () async {
    final digest = 'a' * 64;
    await expectLater(
      capture(source: Directory('${root.path}/missing'), digest: digest),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_unavailable',
        ),
      ),
    );
    await expectLater(
      capture(source: scratch, digest: digest),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_unavailable',
        ),
      ),
    );
  });

  test('non-directory source and symlink roots are untrusted', () async {
    final digest = 'a' * 64;
    final plain = File('${root.path}/plain-file');
    await plain.writeAsString('x', flush: true);
    await expectLater(
      capture(source: Directory(plain.path), digest: digest),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_untrusted',
        ),
      ),
    );
    final target = Directory('${root.path}/link-target');
    await target.create();
    final link = Link('${root.path}/link-source');
    await link.create(target.path);
    await expectLater(
      capture(source: Directory(link.path), digest: digest),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_untrusted',
        ),
      ),
    );
  });

  test('metadata mismatches are invalid and preserve the source', () async {
    final bytes = List<int>.generate(256, (i) => i);
    final digest = sha256.convert(bytes).toString();
    Future<void> expectInvalid(Map<String, Object?> proof) async {
      final source = await _sourceDirectory(
        parent: root,
        databaseBytes: bytes,
        qualification: proof,
      );
      final before = await File('${source.path}/data.mdb').readAsBytes();
      await expectLater(
        capture(source: source, digest: digest),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloud_sync_windows_historical_source_invalid',
          ),
        ),
      );
      expect(await File('${source.path}/data.mdb').readAsBytes(), before);
      expect(scratch.listSync(), isEmpty);
    }

    final good = _qualification(digest: digest, bytes: bytes.length);
    await expectInvalid({...good, 'stable': false});
    await expectInvalid({...good, 'package': 'com.other.app'});
    await expectInvalid({...good, 'bytes': bytes.length + 1});
    await expectInvalid({...good, 'databaseSha256': 'b' * 64});
    await expectInvalid({...good, 'remoteBeforeSha256': 'b' * 64});
    await expectInvalid({...good, 'remoteAfterSha256': 'b' * 64});
    await expectInvalid({...good}..remove('stable'));
  });

  test('oversized metadata is limited', () async {
    final bytes = [1, 2, 3];
    final digest = sha256.convert(bytes).toString();
    final source = await _sourceDirectory(
      parent: root,
      databaseBytes: bytes,
      qualification: _qualification(digest: digest, bytes: bytes.length),
    );
    final proof = File('${source.path}/capture-qualification.json');
    final padded = '${await proof.readAsString()}${' ' * (64 * 1024)}';
    await proof.writeAsString(padded, flush: true);
    await expectLater(
      capture(source: source, digest: digest),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_limit',
        ),
      ),
    );
  });

  test('malformed metadata is invalid', () async {
    final source = await _sourceDirectory(
      parent: root,
      databaseBytes: [1, 2, 3],
      qualification: _qualification(digest: 'a' * 64, bytes: 3),
    );
    await File(
      '${source.path}/capture-qualification.json',
    ).writeAsString('{not json', flush: true);
    await expectLater(
      capture(source: source, digest: 'a' * 64),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_invalid',
        ),
      ),
    );
  });

  test('digest mismatch against actual bytes is invalid', () async {
    final source = await _sourceDirectory(
      parent: root,
      databaseBytes: [1, 2, 3],
      qualification: _qualification(digest: 'b' * 64, bytes: 3),
    );
    await expectLater(
      capture(source: source, digest: 'b' * 64),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_invalid',
        ),
      ),
    );
    expect(scratch.listSync(), isEmpty);
  });

  test('scratch equal to source is untrusted', () async {
    final bytes = [1, 2, 3];
    final digest = sha256.convert(bytes).toString();
    // Valid evidence directly in scratch so the flow reaches scratch-target
    // selection: the generated target would land inside the source.
    await File('${scratch.path}/data.mdb').writeAsBytes(bytes, flush: true);
    await File('${scratch.path}/capture-qualification.json').writeAsString(
      jsonEncode(_qualification(digest: digest, bytes: bytes.length)),
      flush: true,
    );
    final originalEntries = scratch.listSync().map((e) => e.path).toSet();
    await expectLater(
      captureCloudSyncWindowsHistoricalSource(
        sourceDirectory: scratch,
        scratchRoot: scratch,
        expectedDatabaseSha256: digest,
        account: account(),
        accountHandles: const ['owner@example.com'],
        label: 'Alpha history',
        capturedAtMs: DateTime.now().millisecondsSinceEpoch,
        validateIdentity: () async {},
        stillCurrent: () => true,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_untrusted',
        ),
      ),
    );
    expect(await File('${scratch.path}/data.mdb').exists(), isTrue);
    expect(
      scratch.listSync().map((e) => e.path).toSet(),
      originalEntries,
      reason: 'Reject before creating any directory in the evidence source.',
    );
  });

  test('identity loss and failing validation stop the capture', () async {
    await expectLater(
      capture(
        source: Directory('${root.path}/missing'),
        digest: 'a' * 64,
        stillCurrent: () => false,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_identity_changed',
        ),
      ),
    );
    await expectLater(
      capture(
        source: Directory('${root.path}/missing'),
        digest: 'a' * 64,
        validateIdentity: () async {
          throw StateError('synthetic identity failure');
        },
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloud_sync_windows_historical_source_identity_changed',
        ),
      ),
    );
  });

  test(
    'post-copy identity failure cleans only the generated working copy',
    () async {
      final bytes = [1, 2, 3];
      final digest = sha256.convert(bytes).toString();
      final source = await _sourceDirectory(
        parent: root,
        databaseBytes: bytes,
        qualification: _qualification(digest: digest, bytes: bytes.length),
      );
      final retained = File('${scratch.path}/unrelated-proof.txt');
      await retained.writeAsString('keep');
      var validations = 0;
      await expectLater(
        capture(
          source: source,
          digest: digest,
          validateIdentity: () async {
            validations++;
            if (validations == 2) {
              throw Exception('private account and message details');
            }
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'safe failure',
            'cloud_sync_windows_historical_source_identity_changed',
          ),
        ),
      );
      expect(validations, 2);
      final remaining = scratch.listSync();
      expect(remaining, hasLength(1));
      expect(
        FileSystemEntity.identicalSync(remaining.single.path, retained.path),
        isTrue,
      );
      expect(await File('${source.path}/data.mdb').readAsBytes(), bytes);
    },
  );

  test(
    'real-DB capture preserves the source and cleans scratch',
    () async {
      // Requires a working native ObjectBox library; blocked on hosts
      // with Application Control 4551. Do not bypass the block or treat
      // this as executed evidence there.
      final seed = await openStore(directory: '${root.path}/alpha-db');
      final peer = Handle(address: 'peer@example.com', service: 'iMessage');
      final owner = Handle(
        address: 'owner@example.com',
        service: 'iMessage',
        originalROWID: 102,
      );
      seed.box<Handle>().putMany([peer, owner]);
      final chat = Chat(
        guid: 'iMessage;-;peer@example.com',
        chatIdentifier: peer.address,
        usingHandle: 'mailto:owner@example.com',
        style: 45,
        isRpSms: false,
        participants: [peer],
      )..handles.add(peer);
      seed.box<Chat>().put(chat);
      Message message({required String guid, required bool fromMe}) {
        final text = 'alpha row $guid';
        return Message(
          guid: guid,
          text: text,
          attributedBody: [AttributedBody.raw(text)],
          isFromMe: fromMe,
          dateCreated: DateTime.now().subtract(const Duration(days: 3)),
          handle: fromMe ? owner : peer,
        )..chat.target = chat;
      }

      seed.box<Message>().put(message(guid: _t('G'), fromMe: true));
      seed.box<Message>().put(message(guid: _t('H'), fromMe: false));
      seed.close();
      final data = File('${root.path}/alpha-db/data.mdb');
      final digest = (await sha256.bind(data.openRead()).first).toString();
      final source = await _sourceDirectory(
        parent: root,
        databaseBytes: await data.readAsBytes(),
        qualification: _qualification(
          digest: digest,
          bytes: await data.length(),
        ),
      );
      final imported = await capture(source: source, digest: digest);
      expect(imported.label, 'Alpha history');
      expect(imported.snapshot.manifest.messageCount, 2);
      expect(imported.snapshot.manifest.accountHandles, ['owner@example.com']);
      expect(
        imported.identitySha256,
        imported.snapshot.manifest.snapshotSha256,
      );
      expect(scratch.listSync(), isEmpty);
      expect(
        (await sha256.bind(File('${source.path}/data.mdb').openRead()).first)
            .toString(),
        digest,
      );
      expect(
        await File('${source.path}/capture-qualification.json').exists(),
        isTrue,
      );
    },
    tags: ['requires-objectbox'],
  );
}
