import 'dart:ui' as ui;

import 'package:bluebubbles/backend_harness/backend_harness_fixture_assets.dart';
import 'package:bluebubbles/backend_harness/backend_harness_fixtures.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

const fixtureId = '01234567-89AB-CDEF-0123-456789ABCDEF';
const messageGuid = '11234567-89AB-CDEF-0123-456789ABCDEF';
const ownerId = '21234567-89AB-CDEF-0123-456789ABCDEF';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'the synthetic image is decodable without a personal media file',
    () async {
      final codec = await ui.instantiateImageCodec(
        backendFixtureBytes(fixtureId, 'image'),
      );
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 2);
        expect(frame.image.height, 2);
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    },
  );
  final send = <String, Object?>{
    'fixtureId': fixtureId,
    'acknowledgeSend': true,
    'retainedRecoveryOwner': ownerId,
    'recipients': ['+16177106179'],
    'kind': 'text',
  };
  final mutation = <String, Object?>{
    'fixtureId': fixtureId,
    'messageGuid': messageGuid,
    'acknowledgeSend': true,
    'retainedRecoveryOwner': ownerId,
  };

  test('route preflight permits only the exact approved existing-route set', () {
    expect(BackendHarnessFixtures.validRoute({'recipients': ['+16177106179']}), true);
    expect(BackendHarnessFixtures.validRoute({'recipients': ['+19079786948', '+16177106179']}), true);
    for (final value in [
      <String, Object?>{},
      {'recipients': []},
      {'recipients': ['+10000000000']},
      {'recipients': ['+16177106179', '+16177106179']},
      {'recipients': ['+16177106179', '+19079786948', '+10000000000']},
      {'recipients': ['+16177106179'], 'fixtureId': fixtureId},
      {'recipients': ['+16177106179'], 'path': 'caller-path'},
    ]) {
      expect(BackendHarnessFixtures.validRoute(value), false);
    }
  });

  test(
    'fixture send requires explicit scope and supports one bounded group',
    () {
      expect(BackendHarnessFixtures.validSend(send), isTrue);
      expect(
        BackendHarnessFixtures.validSend({
          ...send,
          'recipients': ['+16177106179', '+19079786948'],
        }),
        isTrue,
      );
      for (final recipients in [
        [],
        ['+10000000000'],
        ['+16177106179', '+16177106179'],
        ['+16177106179', '+19079786948', '+10000000000'],
      ]) {
        expect(
          BackendHarnessFixtures.validSend({...send, 'recipients': recipients}),
          isFalse,
        );
      }
      expect(
        BackendHarnessFixtures.validSend({...send, 'acknowledgeSend': false}),
        isFalse,
      );
      expect(
        BackendHarnessFixtures.validSend({
          ...send,
          'retainedRecoveryOwner': '',
        }),
        isFalse,
      );
      expect(
        BackendHarnessFixtures.validSend({...send, 'path': 'arbitrary-file'}),
        isFalse,
      );
    },
  );

  test(
    'writer commands remain unavailable in the ordinary default build',
    () async {
      final fixtures = BackendHarnessFixtures();
      Matcher disabled = throwsA(
        isA<BackendHarnessFailure>().having(
          (failure) => failure.code,
          'code',
          'backend_disabled',
        ),
      );
      await expectLater(fixtures.send(send), disabled);
      await expectLater(fixtures.edit(mutation), disabled);
      await expectLater(fixtures.unsend(mutation), disabled);
    },
  );

  test('fresh group creation is explicit, bounded and text-first', () {
    final group = {...send,
      'recipients': ['+16177106179', '+19079786948'], 'createGroup': true};
    expect(BackendHarnessFixtures.validSend(group), true);
    expect(BackendHarnessFixtures.validRoute({
      'recipients': ['+16177106179', '+19079786948'], 'createGroup': true}), true);
    expect(BackendHarnessFixtures.validRoute({
      'recipients': ['+16177106179'], 'createGroup': true}), false);
    expect(BackendHarnessFixtures.validRoute({
      'recipients': ['+16177106179', '+19079786948'], 'createGroup': false}), false);
    for (final override in <Map<String, Object?>>[
      {'recipients': ['+16177106179']},
      {'recipients': ['+16177106179', '+16177106179']},
      {'recipients': ['+16177106179', '+15555550101']},
      {'kind': 'image'}, {'kind': 'document'}, {'createGroup': false},
      {'createGroup': 'true'}, {'existingGuid': fixtureId},
    ]) {
      expect(BackendHarnessFixtures.validSend({...group, ...override}), false);
    }
  });

  test('fresh group validation refuses a canonical or retargeted route', () {
    final chat = Chat(id: 1, guid: '01234567-89AB-4DEF-8123-456789ABCDEF',
      usingHandle: 'mailto:sender@example.invalid', participants: [
        Handle(address: '+16177106179', service: 'iMessage'),
        Handle(address: '+19079786948', service: 'iMessage'),
      ]);
    // Unsaved participants are deliberately not sufficient; the backend must
    // return its actual persisted handle relation before this check can pass.
    expect(() => BackendHarnessFixtures.requireFreshGroup(chat,
      ['+16177106179', '+19079786948']), throwsA(isA<BackendHarnessFailure>()));
    chat.guid = 'iMessage;+;restored';
    chat.chatIdentifier = 'restored';
    chat.style = 43;
    chat.cloudGuid = 'opaque-group';
    expect(() => BackendHarnessFixtures.requireFreshGroup(chat,
      ['+16177106179', '+19079786948']), throwsA(isA<BackendHarnessFailure>()));
  });

  test(
    'mutation selection refuses a personal message or another conversation',
    () {
      final message = Message(
        text: BackendHarnessFixtures.marker(fixtureId),
        isFromMe: true,
      )..chat.target = Chat(guid: fixtureId);
      expect(BackendHarnessFixtures.ownsMessage(message, fixtureId), isTrue);
      message.text = 'retained personal message';
      expect(BackendHarnessFixtures.ownsMessage(message, fixtureId), isFalse);
      message.text = BackendHarnessFixtures.marker(fixtureId);
      message.chat.target = Chat(guid: ownerId);
      expect(BackendHarnessFixtures.ownsMessage(message, fixtureId), isFalse);
      message.chat.target = Chat(guid: fixtureId);
      message.isFromMe = false;
      expect(BackendHarnessFixtures.ownsMessage(message, fixtureId), isFalse);
    },
  );

  test('scheduled and deleted rows cannot become fixture mutation targets', () {
    final message = Message(
      text: BackendHarnessFixtures.marker(fixtureId),
      isFromMe: true,
    )..chat.target = Chat(guid: fixtureId);
    message.dateScheduled = DateTime.utc(2026, 10, 24);
    expect(BackendHarnessFixtures.ownsMessage(message, fixtureId), isFalse);
    message.dateScheduled = null;
    message.dateDeleted = DateTime.utc(2026, 10, 24);
    expect(BackendHarnessFixtures.ownsMessage(message, fixtureId), isFalse);
  });

  test(
    'private fixture receipts contain only bounded identifiers and digests',
    () {
      final receipt = BackendHarnessFixtureReceipt(
        fixtureId: fixtureId,
        messageGuid: messageGuid,
        visibleTextSha256: 'a' * 64,
      ).toJson();
      expect(BackendHarnessFixtureReceipt.validJson(receipt), isTrue);
      final full = {
        ...receipt,
        'participantsSha256': 'b' * 64,
        'editHistorySha256': 'c' * 64,
      };
      expect(BackendHarnessFixtureReceipt.validJson(full), isTrue);
      expect(BackendHarnessFixtureReceipt.validJson({...full,
        'chatGuidSha256': 'd' * 64}), isTrue);
      expect(BackendHarnessFixtureReceipt.validJson({...full,
        'chatGuidSha256': 'iMessage;+;private-route'}), isFalse);
      expect(BackendHarnessFixtureReceipt.validJson({...receipt,
        'chatGuidSha256': 'd' * 64}), isFalse);
      expect(BackendHarnessFixtureReceipt.validJson({
        ...full, 'editHistorySha256': 'invalid',
      }), isFalse);
      expect(
        BackendHarnessFixtureReceipt.validJson({...receipt, 'body': 'private'}),
        isFalse,
      );
      expect(
        BackendHarnessFixtureReceipt.validJson({
          ...receipt,
          'messageGuid': 'arbitrary',
        }),
        isFalse,
      );
      expect(
        BackendHarnessFixtures.validMutation({
          ...mutation,
          'text': 'arbitrary',
        }),
        isFalse,
      );
      expect(
        BackendHarnessFixtures.validMutation({
          ...mutation,
          'messageGuid': 'temp-id',
        }),
        isFalse,
      );
    },
  );
}
