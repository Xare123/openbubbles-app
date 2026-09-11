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
      // Reuse the forged baseline rows: a parent receipt is no child proof.
      final attachmentRequest = CloudSyncWindowsWriteRequest.fromJson({
        'version': 4,
        'id': 'proof-attachment',
        'allowSend': true,
        'recipient': request.recipient,
        'sender': request.sender,
        'text': '',
        'attachmentFixture': 'png-v1',
      });
      final attachment = Attachment(guid: '${guid}_0');
      store.box<Attachment>().put(attachment);
      message
        ..text = ''
        ..attributedBody = []
        ..hasAttachments = true;
      message.dbAttachments.add(attachment);
      store.box<Message>().put(message);
      final diagnostic = inspectWindowsWriteProof(store, attachmentRequest, {
        ...claim,
        'binding': attachmentRequest.binding,
      });
      expect(diagnostic, {
        'version': 1,
        'state': 'inspected',
        'proof_scope': 'db_only_attachment_diagnostics',
        'request_kind': 'attachment-v4',
        'intent_state': 2,
        'exact_source_validated': report['exact_source_validated'],
        'validation_failure': report['validation_failure'],
        'positive_ids_confirmation': true,
        'single_canonical_message': true,
        'persisted_attachment_count': 1,
        'attachment_upload_row_count': 0,
        'attachment_upload_states': <int>[],
        'attachment_child_operations': <Object>[],
        'attachment_upload_failure': null,
        'parent_operation_present': true,
        'parent_operation_state': 2,
        'parent_readback_marker_matches_admission': true,
        'parent_confirmed_receipt_released': true,
        'parent_save_attempt_count': 0,
        'persisted_readback_proven': false,
      });
      final pending = store.box<CloudOutboxOperationEntity>().getAll().single;
      pending.state = 0;
      store.box<CloudOutboxOperationEntity>().put(pending);
      final pendingReport = inspectWindowsWriteProof(store, attachmentRequest, {
        ...claim,
        'binding': attachmentRequest.binding,
      });
      expect(pendingReport['parent_operation_state'], 0);
      expect(pendingReport['parent_confirmed_receipt_released'], isFalse);
      expect(pendingReport['persisted_readback_proven'], isFalse);
      store.box<CloudOutboxOperationEntity>().removeAll();
      final absentReport = inspectWindowsWriteProof(store, attachmentRequest, {
        ...claim,
        'binding': attachmentRequest.binding,
      });
      expect(absentReport['parent_operation_present'], isFalse);
      expect(absentReport['parent_operation_state'], isNull);
      expect(absentReport['parent_confirmed_receipt_released'], isFalse);
      expect(absentReport['parent_save_attempt_count'], isNull);
      expect(absentReport['persisted_readback_proven'], isFalse);
    },
  );
  test('upload diagnostics filter exact account and intent', () {
    final account = claim['account'] as String;
    for (final (key, ownerAccount, ownerIntent, state) in [
      ('one', account, 7, 3),
      ('two', account, 7, 2),
      ('other-intent', account, 8, 0),
      ('other-account', 'B' * 43, 7, 1),
    ]) {
      store.box<CloudAttachmentUploadEntity>().put(
        CloudAttachmentUploadEntity(
          uploadKey: key,
          accountFingerprint: ownerAccount,
          writerEpoch: 1,
          checkpointGeneration: 1,
          localSendIntentId: ownerIntent,
          messageGuidHash: 'a' * 64,
          sourceSha256: 'b' * 64,
          protectedStoreIdentity: 'synthetic-store',
          attachmentKeyHash: 'C' * 43,
          serverRecordIdHash: 'D' * 43,
          planReference: 'synthetic-plan',
          planLeaseReference: 'synthetic-lease',
          planPayloadSha256: 'c' * 64,
          state: state,
          createdAtMs: 1,
          updatedAtMs: 2,
        ),
      );
    }
    expect(
      readAttachmentUploadDiagnostic(
        store,
        intentId: 7,
        accountFingerprint: account,
      ),
      {
        'attachment_upload_row_count': 2,
        'attachment_upload_states': [2, 3],
        'attachment_child_operations': [
          {'matching_operations': 0},
          {'matching_operations': 0},
        ],
        'attachment_upload_failure': null,
      },
    );
    final uploadBox = store.box<CloudAttachmentUploadEntity>();
    final upload = uploadBox.getAll().singleWhere(
      (row) => row.uploadKey == 'one',
    )..admittedOperationId = 'child-operation';
    uploadBox.put(upload);
    final operation = CloudOutboxOperationEntity(
      operationId: 'child-operation',
      scopeKey: 'synthetic-scope',
      accountFingerprint: 'B' * 43,
      zone: 'attachmentManateeZone',
      logicalEntityKeyHash: 'C' * 43,
      action: 0,
      mutationRevision: 1,
      checkpointGeneration: 1,
      serverRecordIdHash: 'D' * 43,
      createdAtMs: 1,
      updatedAtMs: 2,
    );
    final operationBox = store.box<CloudOutboxOperationEntity>();
    operationBox.put(operation);
    List<Object?> children() =>
        readAttachmentUploadDiagnostic(
              store,
              intentId: 7,
              accountFingerprint: account,
            )['attachment_child_operations']
            as List<Object?>;
    expect(children(), everyElement({'matching_operations': 0}));
    operation
      ..accountFingerprint = account
      ..zone = 'messageManateeZone';
    operationBox.put(operation);
    expect(children(), everyElement({'matching_operations': 0}));
    operation.zone = 'attachmentManateeZone';
    operationBox.put(operation);
    expect(
      children(),
      contains(equals({
        'matching_operations': 1,
        'state': 0,
        'attempt_count': 0,
        'generation_matches_upload': true,
        'record_matches_upload': true,
        'payload_reference_retained': false,
        'receipt_lease_retained': false,
        'confirmed_timestamp_present': false,
      })),
    );
  });
  test('upload query failure reports nulls instead of zero rows', () async {
    store.close();
    try {
      expect(
        readAttachmentUploadDiagnostic(
          store,
          intentId: 7,
          accountFingerprint: claim['account'] as String,
        ),
        {
          'attachment_upload_row_count': null,
          'attachment_upload_states': null,
          'attachment_child_operations': null,
          'attachment_upload_failure':
              'cloud_sync_windows_proof_upload_query_failed',
        },
      );
    } finally {
      store = await openStore(directory: directory.path);
    }
  });
}
