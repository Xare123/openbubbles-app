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
