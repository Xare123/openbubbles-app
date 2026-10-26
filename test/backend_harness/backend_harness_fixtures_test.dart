import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/backend_harness/backend_harness_fixture_assets.dart';
import 'package:bluebubbles/backend_harness/backend_harness_fixtures.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_send_body.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/services.dart' show fs;
import 'package:flutter_test/flutter_test.dart';

const fixtureId = '01234567-89AB-CDEF-0123-456789ABCDEF';
const messageGuid = '11234567-89AB-CDEF-0123-456789ABCDEF';
const ownerId = '21234567-89AB-CDEF-0123-456789ABCDEF';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('normal merged fixture result', () {
    late Directory directory;
    late Chat chat;
    var cacheIndex = 0;

    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp('fixture-merged-result-');
      Database.store = await openStore(directory: directory.path);
      Database.messages = Database.store.box<Message>();
      Database.chats = Database.store.box<Chat>();
      Database.handles = Database.store.box<Handle>();
      Database.attachments = Database.store.box<Attachment>();
    });
    setUp(() {
      Database.attachments.removeAll();
      Database.store.box<CloudSyncLocalSendIntentEntity>().removeAll();
      Database.messages.removeAll(); // This group's disposable store only.
      Database.chats.removeAll();
      Database.handles.removeAll();
      fs.appDocDir = Directory('${directory.path}/cache-${cacheIndex++}')..createSync();
      chat = Chat(guid: 'iMessage;-;+16177106179', style: 45,
        chatIdentifier: '+16177106179', usingHandle: 'mailto:self@example.invalid');
      Database.chats.put(chat);
    });
    tearDownAll(() async {
      Database.store.close();
      final resolved = Directory(await directory.resolveSymbolicLinks());
      expect(resolved.parent.path, await Directory.systemTemp.resolveSymbolicLinks());
      expect(resolved.uri.pathSegments.where((part) => part.isNotEmpty).last,
        startsWith('fixture-merged-result-'));
      expect(await FileSystemEntity.type(directory.path, followLinks: false),
        FileSystemEntityType.directory);
      await directory.delete(recursive: true);
    });

    Message requireMerged(String? guid) => BackendHarnessFixtures.requireMergedMessage(
      store: Database.store, chat: chat, fixtureId: fixtureId, messageGuid: guid,
    );

    ({Message pending, Message reflected, Attachment attachment,
      CloudSyncLocalSendIntentEntity origin}) attachmentReflection() {
      const guid = '11234567-89AB-4DEF-8123-456789ABCDEF';
      const descriptor = '<attachment><fixture>original-mmcs</fixture></attachment>';
      chat
        ..guid = 'iMessage;+;fixture-group'
        ..chatIdentifier = 'fixture-group'
        ..cloudGuid = 'opaque-fixture-group'
        ..style = 43;
      for (final address in BackendHarnessFixtures.recipients) {
        final handle = Handle(address: address, service: 'iMessage',
          uniqueAddressAndService: '$address/iMessage');
        Database.handles.put(handle);
        chat.handles.add(handle);
      }
      Database.chats.put(chat);
      final bytes = backendFixtureBytes(fixtureId, 'image');
      final attachment = Attachment(guid: 'local-original-attachment',
        transferName: 'fixture.png', mimeType: 'image/png', uti: 'public.png',
        isOutgoing: true, totalBytes: bytes.length, metadata: {'rustpush': descriptor});
      final pending = BackendHarnessFixtures.prepareAttachment(fixtureId, attachment)
        ..guid = guid
        ..chat.target = chat;
      Database.messages.put(pending);
      attachment.save(pending);
      File(attachment.path)..createSync(recursive: true)..writeAsBytesSync(bytes);
      final identity = CloudSyncLocalSendIdentity.captureAttachment(pending, chat, guid)!;
      final source = CloudSyncLocalSendSourceBinding(
        accountFingerprint: 'A' * 43, protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
        messageGuidHash: identity.guidHash, sourceSha256: identity.sourceSha256,
        protectedReference: 'obcs2.ref.${'C' * 43}', leaseReference: 'obcs2.lease.${'d' * 32}',
        payloadSha256: 'e' * 64, payloadLength: 1009,
      );
      final origin = CloudSyncLocalSendIntentEntity(
        intentKey: 'fixture-attachment-intent', accountFingerprint: source.accountFingerprint,
        writerEpoch: 1, localMessageId: pending.id!, messageGuidHash: identity.guidHash,
        sourceSha256: identity.sourceSha256, state: 1, idsConfirmationVersion: 2,
        protectedSourceBinding: source.encode(), createdAtMs: 1, updatedAtMs: 1,
      );
      Database.store.box<CloudSyncLocalSendIntentEntity>().put(origin);
      final replacement = Attachment(guid: '${guid}_0',
        transferName: attachment.transferName, mimeType: attachment.mimeType, uti: attachment.uti,
        isOutgoing: false, totalBytes: attachment.totalBytes, metadata: {'rustpush': descriptor});
      final text = BackendHarnessFixtures.marker(fixtureId);
      final reflected = Message(guid: guid, text: '$text ', isFromMe: true,
        dateCreated: pending.dateCreated, hasAttachments: true, attachments: [replacement],
        attributedBody: [AttributedBody(string: '$text ', runs: [
          Run(range: [0, text.length], attributes: Attributes(messagePart: 0)),
          Run(range: [text.length, 1],
            attributes: Attributes(messagePart: 1, attachmentGuid: replacement.guid)),
        ])]);
      return (pending: pending, reflected: reflected, attachment: attachment, origin: origin);
    }

    test('attachment reflection preserves the row, cache, descriptor and exact source', () async {
      final fixture = attachmentReflection();
      final originalPath = fixture.attachment.path;
      final broken = Database.messages.get(fixture.pending.id!)!
        ..text = fixture.reflected.text
        ..attributedBody = fixture.reflected.attributedBody;
      // Actual failure shape: reflected ..._0 body, original linked GUID.
      expect(CloudSyncAttachmentSendBody.capture(broken), isNull);

      await BackendHarnessFixtures.reconcileAttachmentReflection(
        store: Database.store, chat: chat, fixtureId: fixtureId,
        pending: fixture.pending, reflected: fixture.reflected,
      );
      await ActionHandler().matchMessageWithExisting(
        chat, fixture.pending.guid!, fixture.reflected, existing: fixture.pending,
      );

      final canonical = requireMerged(fixture.reflected.guid);
      final linked = canonical.dbAttachments.single;
      expect(canonical.id, fixture.pending.id);
      expect(linked.id, fixture.attachment.id);
      expect(linked.message.targetId, canonical.id);
      expect(linked.guid, fixture.reflected.attachments.single!.guid);
      expect(linked.dbMetadata, fixture.attachment.dbMetadata);
      expect(File(originalPath).existsSync(), isFalse);
      expect(File(linked.path).readAsBytesSync(), backendFixtureBytes(fixtureId, 'image'));
      expect(CloudSyncLocalSendIdentity.captureAttachment(canonical, chat, canonical.guid!,
        expectedSourceSha256: fixture.origin.sourceSha256)?.sourceSha256,
        fixture.origin.sourceSha256);
      final retained = Database.store.box<CloudSyncLocalSendIntentEntity>().get(fixture.origin.id)!;
      expect(retained.protectedSourceBinding, fixture.origin.protectedSourceBinding);
      expect(retained.sourceSha256, fixture.origin.sourceSha256);
      expect(retained.messageGuidHash, fixture.origin.messageGuidHash);
      expect(retained.state, 1);
      expect(retained.idsConfirmationVersion, 2);
      expect(Database.attachments.count(), 1);
      expect(Database.messages.count(), 1);
    });

    for (final mismatch in [
      'descriptor', 'multiple attachments', 'wrong owner', 'collision', 'cache collision',
    ]) {
      test('attachment reflection refuses $mismatch before changing the original', () async {
        final fixture = attachmentReflection();
        final replacement = fixture.reflected.attachments.single!;
        switch (mismatch) {
          case 'descriptor':
            replacement.metadata = {'rustpush': '<attachment>different-mmcs</attachment>'};
          case 'multiple attachments':
            fixture.reflected.attachments.add(Attachment(guid: 'unrelated'));
          case 'wrong owner':
            replacement.guid = '${ownerId}_0';
            final body = fixture.reflected.attributedBody.single;
            fixture.reflected.attributedBody = [AttributedBody(string: body.string, runs: [
              body.runs.first,
              Run(range: body.runs.last.range,
                attributes: Attributes(messagePart: 1, attachmentGuid: replacement.guid)),
            ])];
          case 'collision':
            final other = Message(guid: ownerId)..chat.target = chat;
            Database.messages.put(other);
            Attachment(guid: replacement.guid, metadata: replacement.metadata).save(other);
          case 'cache collision':
            Directory(replacement.directory).createSync(recursive: true);
        }
        final attachmentCount = Database.attachments.count();
        await expectLater(BackendHarnessFixtures.reconcileAttachmentReflection(
          store: Database.store, chat: chat, fixtureId: fixtureId,
          pending: fixture.pending, reflected: fixture.reflected,
        ), throwsA(isA<BackendHarnessFailure>()));
        final original = Database.attachments.get(fixture.attachment.id!)!;
        expect(original.guid, fixture.attachment.guid);
        expect(original.message.targetId, fixture.pending.id);
        expect(original.dbMetadata, fixture.attachment.dbMetadata);
        expect(Database.attachments.count(), attachmentCount);
        expect(File(original.path).readAsBytesSync(), backendFixtureBytes(fixtureId, 'image'));
        expect(Database.messages.get(fixture.pending.id!)!.text, fixture.pending.text);
        expect(Database.store.box<CloudSyncLocalSendIntentEntity>().get(fixture.origin.id)!
          .protectedSourceBinding, fixture.origin.protectedSourceBinding);
      });
    }

    for (final normalized in [false, true]) {
      test('detached reflection validates the persisted merge, normalized=$normalized', () async {
        final pending = Message(
          guid: normalized ? messageGuid : 'temp-pending',
          text: BackendHarnessFixtures.marker(fixtureId), isFromMe: true,
        )..chat.target = chat;
        Database.messages.put(pending);
        final reflected = Message(guid: messageGuid, isFromMe: true,
          dateDelivered: DateTime.utc(2026, 10, 25));

        await ActionHandler().matchMessageWithExisting(
          chat, pending.guid!, reflected, existing: pending,
        );

        // The old post-send check rejected this detached object even though
        // the normal merger kept the fixture body and Chat on the saved row.
        expect(reflected.chat.target, isNull);
        expect(reflected.text, isNull);
        expect(BackendHarnessFixtures.ownsMessage(reflected, fixtureId,
          exactMessageGuid: messageGuid), isFalse);
        final canonical = requireMerged(reflected.guid);
        expect(canonical.id, pending.id);
        expect(canonical.guid, messageGuid);
        expect(canonical.chat.targetId, chat.id);
        expect(canonical.text, BackendHarnessFixtures.marker(fixtureId));
        expect(canonical.isFromMe, isTrue);
        expect(canonical.dateDelivered!.toUtc(), reflected.dateDelivered!.toUtc());
        expect(Database.messages.count(), 1);
      });
    }

    test('readback refuses wrong GUID, staging-only or missing results', () {
      final pending = Message(guid: 'temp-pending', stagingGuid: messageGuid,
        text: BackendHarnessFixtures.marker(fixtureId), isFromMe: true)
        ..chat.target = chat;
      Database.messages.put(pending);
      for (final guid in [null, 'temp-pending', messageGuid, ownerId]) {
        expect(() => requireMerged(guid), throwsA(isA<BackendHarnessFailure>()));
      }
      expect(Database.messages.get(pending.id!)!.guid, 'temp-pending');
      expect(Database.messages.count(), 1);
    });

    test('readback refuses wrong marker, direction or unrelated Chat', () {
      final otherChat = Chat(guid: 'iMessage;-;other@example.invalid');
      Database.chats.put(otherChat);
      final message = Message(guid: messageGuid,
        text: BackendHarnessFixtures.marker(fixtureId), isFromMe: true)
        ..chat.target = chat;
      Database.messages.put(message);
      for (final change in <void Function()>[
        () => message.text = BackendHarnessFixtures.marker(ownerId),
        () { message.text = BackendHarnessFixtures.marker(fixtureId); message.isFromMe = false; },
        () { message.isFromMe = true; message.chat.target = otherChat; },
        () => message.chat.target = null,
        () { message.chat.target = chat; message.dateScheduled = DateTime.utc(2026, 10, 25); },
        () { message.dateScheduled = null; message.dateDeleted = DateTime.utc(2026, 10, 25); },
      ]) {
        change();
        Database.messages.put(message);
        expect(() => requireMerged(messageGuid), throwsA(isA<BackendHarnessFailure>()));
      }
      expect(Database.messages.count(), 1);
      expect(Database.chats.count(), 2);
    });
  });

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

  test('an exact parent is bounded to an existing approved group for route and send', () {
    final group = ['+16177106179', '+19079786948'];
    final pin = 'a' * 64;
    expect(BackendHarnessFixtures.validRoute({'recipients': group, 'chatGuidSha256': pin}), isTrue);
    for (final kind in ['text', 'image', 'document']) {
      expect(BackendHarnessFixtures.validSend({...send, 'recipients': group,
        'kind': kind, 'chatGuidSha256': pin}), isTrue);
    }
    for (final value in <Object?>[null, false, '', 'A' * 64, 'g' * 64, 'a' * 63]) {
      expect(BackendHarnessFixtures.validRoute({'recipients': group, 'chatGuidSha256': value}), isFalse);
      expect(BackendHarnessFixtures.validSend({...send, 'recipients': group, 'chatGuidSha256': value}), isFalse);
    }
    expect(BackendHarnessFixtures.validRoute({'recipients': [group.first], 'chatGuidSha256': pin}), isFalse);
    expect(BackendHarnessFixtures.validSend({...send, 'chatGuidSha256': pin}), isFalse);
    expect(BackendHarnessFixtures.validRoute({'recipients': group, 'createGroup': true, 'chatGuidSha256': pin}), isFalse);
    expect(BackendHarnessFixtures.validSend({...send, 'recipients': group, 'createGroup': true, 'chatGuidSha256': pin}), isFalse);
    expect(BackendHarnessFixtures.validSend({...send, 'recipients': group, 'acknowledgeSend': false, 'chatGuidSha256': pin}), isFalse);
    expect(BackendHarnessFixtures.validSend({...send, 'recipients': ['+16177106179', '+15555550101'], 'chatGuidSha256': pin}), isFalse);
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
