import 'dart:convert';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Parser-only qualification for direct-text edit/unsend (request version 6).
// Every identity below is synthetic: 555-01XX numbers are the NANP fictional
// range and senders live under .invalid. No accounts, devices, or files.
void main() {
  Map<String, dynamic> mutationRequest() => {
        'version': 6,
        'id': 'mutation-edit-1',
        'allowSend': true,
        'recipient': '+15555550100',
        'sender': 'mutation-sender@example.invalid',
        'existingChatFromRequestId': 'mutation-parent-1',
        'mutationType': 'edit',
        'mutationPart': 0,
        'text': 'Edited text',
      };

  test('v6 edit request is accepted and bound under windows-local-write-v6',
      () {
    final input = mutationRequest();
    final req = CloudSyncWindowsWriteRequest.fromJson(input);
    expect(req.mutationType, 'edit');
    expect(req.mutationPart, 0);
    expect(req.existingChatFromRequestId, 'mutation-parent-1');
    expect(
      req.binding,
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'windows-local-write-v6',
                'mutation-edit-1',
                '+15555550100',
                'mutation-sender@example.invalid',
                'mutation-parent-1',
                'edit',
                0,
                'Edited text',
              ]),
            ),
          )
          .toString(),
    );
    final repair = CloudSyncWindowsWriteRequest.fromJson({
      ...input,
      'refreshSenderAuthentication': true,
    });
    expect(repair.refreshSenderAuthentication, isTrue);
    expect(repair.binding, isNot(req.binding));
  });

  test('v6 unsend request is accepted with empty text', () {
    final req = CloudSyncWindowsWriteRequest.fromJson({
      ...mutationRequest(),
      'id': 'mutation-unsend-1',
      'mutationType': 'unsend',
      'text': '',
    });
    expect(req.mutationType, 'unsend');
    expect(req.mutationPart, 0);
    expect(req.text, isEmpty);
    expect(
      req.binding,
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'windows-local-write-v6',
                'mutation-unsend-1',
                '+15555550100',
                'mutation-sender@example.invalid',
                'mutation-parent-1',
                'unsend',
                0,
                '',
              ]),
            ),
          )
          .toString(),
    );
    expect(
      req.binding,
      isNot(
        CloudSyncWindowsWriteRequest.fromJson(mutationRequest()).binding,
      ),
    );
  });

  test('v6 rejects ambiguous mutation combinations', () {
    final base = mutationRequest();
    for (final changes in [
      {'reactionType': 'like', 'reactionPart': 0, 'text': ''},
      {'attachmentFixture': 'png-v1', 'text': ''},
      {'restoredGroupGuid': 'iMessage;+;other'},
      {
        'recipients': ['+15555550100', '+15555550101'],
      },
    ]) {
      expect(
        () => CloudSyncWindowsWriteRequest.fromJson({...base, ...changes}),
        throwsStateError,
      );
    }
  });

  test('v6 rejects a bad mutation part', () {
    final base = mutationRequest();
    for (final changes in [
      {'mutationPart': '0'},
      {'mutationPart': 1.0},
      {'mutationPart': true},
      {'mutationPart': -1},
      {'mutationPart': 1},
      {'mutationPart': null},
    ]) {
      expect(
        () => CloudSyncWindowsWriteRequest.fromJson({...base, ...changes}),
        throwsStateError,
      );
    }
    expect(
      () =>
          CloudSyncWindowsWriteRequest.fromJson({...base}..remove('mutationPart')),
      throwsStateError,
    );
  });

  test('v6 requires a distinct valid parent request', () {
    final base = mutationRequest();
    for (final parent in [null, '', '../parent', 'mutation-edit-1']) {
      expect(
        () => CloudSyncWindowsWriteRequest.fromJson({
          ...base,
          'existingChatFromRequestId': parent,
        }),
        throwsStateError,
      );
    }
    expect(
      () => CloudSyncWindowsWriteRequest.fromJson(
          {...base}..remove('existingChatFromRequestId')),
      throwsStateError,
    );
  });

  test('v6 validates mutation type and text bounds', () {
    final base = mutationRequest();
    for (final changes in [
      {'mutationType': 'delete'},
      {'mutationType': ''},
      {'mutationType': 'Edit'},
      {'mutationType': 7},
      {'text': '   '},
      {'text': 'x' * 513},
      {'mutationType': 'unsend', 'text': 'should be empty'},
    ]) {
      expect(
        () => CloudSyncWindowsWriteRequest.fromJson({...base, ...changes}),
        throwsStateError,
      );
    }
    expect(
      () => CloudSyncWindowsWriteRequest.fromJson(
          {...base}..remove('mutationType')),
      throwsStateError,
    );
    final boundary = CloudSyncWindowsWriteRequest.fromJson({
      ...base,
      'text': 'x' * 512,
    });
    expect(boundary.text, hasLength(512));
  });

  test('v6 reuses sender, recipient, and authorization qualification', () {
    final base = mutationRequest();
    for (final changes in [
      {'allowSend': false},
      {'id': '../escape'},
      {'recipient': 'someone@example.invalid'},
      {'sender': 'not-an-address'},
      {'refreshSenderAuthentication': 'yes'},
    ]) {
      expect(
        () => CloudSyncWindowsWriteRequest.fromJson({...base, ...changes}),
        throwsStateError,
      );
    }
  });

  test('older versions reject mutation fields', () {
    Map<String, dynamic> v1() => {
          'version': 1,
          'id': 'mutation-legacy-1',
          'allowSend': true,
          'recipient': '+15555550100',
          'sender': 'mutation-sender@example.invalid',
          'text': 'Legacy text',
        };
    final v2 = {
      ...v1(),
      'version': 2,
      'existingChatFromRequestId': 'mutation-parent-1',
    };
    final v3 = {
      'version': 3,
      'id': 'mutation-legacy-3',
      'allowSend': true,
      'recipients': ['+15555550101', '+15555550100'],
      'sender': 'mutation-sender@example.invalid',
      'text': 'Legacy group text',
      'restoredGroupGuid': 'iMessage;+;chat-synthetic-1',
    };
    final v4 = {
      ...v1(),
      'version': 4,
      'text': '',
      'attachmentFixture': 'png-v1',
    };
    final v5 = {
      ...v1(),
      'version': 5,
      'text': '',
      'reactionType': 'like',
      'reactionPart': 0,
      'existingChatFromRequestId': 'mutation-parent-1',
    };
    for (final base in [v1(), v2, v3, v4, v5]) {
      expect(
        CloudSyncWindowsWriteRequest.fromJson(base).mutationType,
        isNull,
      );
      expect(
        CloudSyncWindowsWriteRequest.fromJson(base).mutationPart,
        isNull,
      );
    }
    for (final base in [v1(), v2, v3, v4, v5]) {
      for (final changes in [
        {'mutationType': 'edit'},
        {'mutationPart': 0},
        {'mutationType': 'edit', 'mutationPart': 0},
        {'mutationType': 'unsend', 'mutationPart': 0},
      ]) {
        expect(
          () => CloudSyncWindowsWriteRequest.fromJson({...base, ...changes}),
          throwsStateError,
        );
      }
    }
  });
}
