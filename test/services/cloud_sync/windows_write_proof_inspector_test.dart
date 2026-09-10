import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../tooling/cloud_sync/inspect_windows_write_proof.dart';

void main() {
  late Directory directory;
  late Store store;
  final request = CloudSyncWindowsWriteRequest.fromJson({
    'version': 1,
    'id': 'proof-test',
    'allowSend': true,
    'recipient': '+15555550100',
    'sender': 'sender@example.com',
    'text': 'Test body',
  });
  const guid = '11111111-2222-4333-8444-555555555555';
  final claim = {
    'version': 1,
    'account': 'A' * 43,
    'guid': guid,
    'binding': request.binding,
  };
  setUp(() async {
    final scratchRoot = Directory('${Directory.current.path}/build')
      ..createSync(recursive: true);
    directory = await scratchRoot.createTemp('write-proof-unit-');
    store = await openStore(directory: directory.path);
  });
  tearDown(() {
    store.close();
    for (final file in directory.listSync(followLinks: false)) {
      expect(file, isA<File>());
      expect(const {
        'data.mdb',
        'lock.mdb',
      }, contains(file.uri.pathSegments.last));
      file.deleteSync();
    }
    directory.deleteSync();
  });
  test('unclaimed and claimed-without-intent are not write proof', () {
    expect(
      inspectWindowsWriteProof(store, request, null)['state'],
      'unclaimed',
    );
    final report = inspectWindowsWriteProof(store, request, claim);
    expect(report['state'], 'claim_without_intent');
    expect(report['persisted_readback_proven'], isFalse);
  });
  test('request drift is rejected, not rebound to a convenient message', () {
    expect(
      () => inspectWindowsWriteProof(store, request, {
        ...claim,
        'binding': 'b' * 64,
      }),
      throwsStateError,
    );
  });
  test(
    'forged matching markers and save flags cannot replace production binding proof',
    () {
      final chat = Chat(
        guid: 'iMessage;-;+15555550100',
        usingHandle: 'mailto:sender@example.com',
        style: 45,
      );
      store.box<Chat>().put(chat);
      final message = Message(
        guid: guid,
        text: request.text,
        isFromMe: true,
        attributedBody: [AttributedBody.raw(request.text)],
      )..chat.target = chat;
      final messageId = store.box<Message>().put(message);
      store.box<CloudSyncLocalSendIntentEntity>().put(
        CloudSyncLocalSendIntentEntity(
          intentKey: 'fake-intent',
          accountFingerprint: 'A' * 43,
          writerEpoch: 1,
          localMessageId: messageId,
          messageGuidHash: sha256
              .convert(
                utf8.encode(
                  jsonEncode(['cloud-sync-local-send-guid-v1', guid]),
                ),
              )
              .toString(),
          sourceSha256: 'a' * 64,
          state: 2,
          admittedOperationId: 'operation',
          admittedBindingSha256: 'b' * 64,
          confirmedReadbackBindingSha256: 'b' * 64,
          idsConfirmationVersion: 2,
          createdAtMs: 1,
          updatedAtMs: 2,
        ),
      );
      store.box<CloudOutboxOperationEntity>().put(
        CloudOutboxOperationEntity(
          operationId: 'operation',
          scopeKey: 'scope',
          accountFingerprint: 'A' * 43,
          zone: 'messageManateeZone',
          logicalEntityKeyHash: 'C' * 43,
          action: 0,
          mutationRevision: 1,
          state: 2,
          serverRecordIdHash: 'D' * 43,
          confirmedAtMs: 2,
          createdAtMs: 1,
          updatedAtMs: 2,
        ),
      );
      final report = inspectWindowsWriteProof(store, request, claim);
      expect(report['readback_marker_matches_admission'], isTrue);
      expect(report['confirmed_receipt_released'], isTrue);
      expect(report['legible_test_body_matches'], isTrue);
      expect(report['exact_source_validated'], isFalse);
      expect(report['persisted_readback_proven'], isFalse);
      final encoded = jsonEncode(report);
      for (final privateValue in [
        guid,
        request.text,
        request.sender,
        request.recipient,
        claim['account'] as String,
      ]) {
        expect(encoded, isNot(contains(privateValue)));
      }
    },
  );
}
