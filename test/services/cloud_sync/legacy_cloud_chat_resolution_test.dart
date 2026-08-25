import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late Box<Chat> chats;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-legacy-cloud-chat-resolution-',
    );
    store = await openStore(directory: directory.path);
    chats = store.box<Chat>();
  });

  tearDown(() async {
    store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('resolves an exact semicolon-bearing cloud group id', () {
    final expected = Chat(
      guid: 'local-guid',
      chatIdentifier: 'current-chat-identifier',
    )..cloudGuid = 'iMessage;+;historical-cloud-group';
    chats.put(expected);

    final result = Chat.findEligibleCloudMessageChat(
      'iMessage;+;historical-cloud-group',
      box: chats,
    );

    expect(result?.id, expected.id);
  });

  test('falls back from a composite reference to its chat identifier', () {
    final expected = Chat(
      guid: 'local-guid',
      chatIdentifier: 'chat-identifier',
    );
    chats.put(expected);

    final result = Chat.findEligibleCloudMessageChat(
      'iMessage;-;chat-identifier',
      box: chats,
    );

    expect(result?.id, expected.id);
  });

  test('resolves a composite reference containing a tel URI', () {
    final expected = Chat(guid: 'local-guid', chatIdentifier: '+15555550100');
    chats.put(expected);

    final result = Chat.findEligibleCloudMessageChat(
      'iMessage;-;tel:+15555550100',
      box: chats,
    );

    expect(result?.id, expected.id);
  });

  test('resolves a composite reference containing a mailto URI', () {
    final expected = Chat(
      guid: 'local-guid',
      chatIdentifier: 'user@example.com',
    );
    chats.put(expected);

    final result = Chat.findEligibleCloudMessageChat(
      'iMessage;-;mailto:user@example.com',
      box: chats,
    );

    expect(result?.id, expected.id);
  });

  test('resolves legacy group aliases retained by the current chat', () {
    final expected = Chat(
      guid: 'current-guid',
      chatIdentifier: 'current-chat-identifier',
      guidRefs: const ['current-guid', 'legacy-group-id'],
    );
    chats.put(expected);

    final result = Chat.findEligibleCloudMessageChat(
      'legacy-group-id',
      box: chats,
    );

    expect(result?.id, expected.id);
  });

  test(
    'never selects an SMS chat or routing stub with the same identifier',
    () {
      chats.put(
        Chat(
          guid: 'sms-guid',
          chatIdentifier: 'shared-identifier',
          isRpSms: true,
        ),
      );
      chats.put(
        Chat(
          guid: 'routing-guid',
          chatIdentifier: 'shared-identifier',
          isRoutingStub: true,
        ),
      );
      final expected = Chat(
        guid: 'imessage-guid',
        chatIdentifier: 'shared-identifier',
      );
      chats.put(expected);

      final result = Chat.findEligibleCloudMessageChat(
        'shared-identifier',
        box: chats,
      );

      expect(result?.id, expected.id);
    },
  );

  test('cloud chat aliases include original and legacy group identities', () {
    final aliases = Chat.cloudIdentityAliases(
      api.CloudChat(
        style: 43,
        isFiltered: 0,
        successfulQuery: 1,
        state: 3,
        chatIdentifier: 'chat-identifier',
        groupId: 'current-group',
        serviceName: 'iMessage',
        originalGroupId: 'original-group',
        properties: api.CloudProp(
          legacyGroupIdentifiers: const ['legacy-group'],
        ),
        participants: const [],
        prop001: const api.CloudProp001(syndicationType: 0),
        lastReadMessageTimestamp: 0,
        lastAddressedHandle: 'user@example.com',
        guid: 'iMessage;+;chat-identifier',
      ),
    );

    expect(
      aliases,
      containsAll(<String>[
        'current-group',
        'original-group',
        'legacy-group',
        'chat-identifier',
        'iMessage;+;chat-identifier',
      ]),
    );
  });

  test('cloud chat aliases retain both composite and bare identities', () {
    final aliases = Chat.cloudIdentityAliases(
      _cloudChat(
        chatIdentifier: 'iMessage;-;+15555550100',
        guid: 'iMessage;-;+15555550100',
      ),
    );

    expect(aliases, containsAll(['iMessage;-;+15555550100', '+15555550100']));
  });

  test('normalizes CloudKit participant URI schemes', () {
    expect(
      Chat.normalizeCloudParticipantAddress('tel:+15555550100'),
      '+15555550100',
    );
    expect(
      Chat.normalizeCloudParticipantAddress('mailto:user@example.com'),
      'user@example.com',
    );
  });

  test('identity candidates normalize nested participant URI schemes', () {
    expect(
      Chat.cloudIdentityCandidates('iMessage;-;tel:+15555550100'),
      containsAll([
        'iMessage;-;tel:+15555550100',
        'tel:+15555550100',
        '+15555550100',
      ]),
    );
    expect(
      Chat.cloudIdentityCandidates('iMessage;-;mailto:user@example.com'),
      containsAll([
        'iMessage;-;mailto:user@example.com',
        'mailto:user@example.com',
        'user@example.com',
      ]),
    );
  });

  test('reference diagnostics expose only the identifier shape', () {
    expect(
      Chat.cloudIdentityReferenceShape('iMessage;-;tel:+15555550100'),
      'composite_tel',
    );
    expect(
      Chat.cloudIdentityReferenceShape('iMessage;-;mailto:user@example.com'),
      'composite_mailto',
    );
    expect(
      Chat.cloudIdentityReferenceShape('iMessage;+;group-identifier'),
      'composite_bare',
    );
    expect(Chat.cloudIdentityReferenceShape('bare-identifier'), 'bare');
  });
}

api.CloudChat _cloudChat({
  required String chatIdentifier,
  required String guid,
}) {
  return api.CloudChat(
    style: 45,
    isFiltered: 0,
    successfulQuery: 1,
    state: 3,
    chatIdentifier: chatIdentifier,
    groupId: 'current-group',
    serviceName: 'iMessage',
    originalGroupId: 'original-group',
    properties: api.CloudProp(legacyGroupIdentifiers: const []),
    participants: const [],
    prop001: const api.CloudProp001(syndicationType: 0),
    lastReadMessageTimestamp: 0,
    lastAddressedHandle: 'user@example.com',
    guid: guid,
  );
}
