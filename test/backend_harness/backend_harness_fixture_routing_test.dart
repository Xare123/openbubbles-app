import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_fixture_routing.dart';
import 'package:bluebubbles/backend_harness/backend_harness_fixtures.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const first = '+16177106179';
const second = '+19079786948';
const sender = 'sender@example.invalid';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Store store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('backend-fixture-route-');
    store = await openStore(directory: directory.path);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  Chat chat({bool group = false, String suffix = 'existing'}) {
    final handles = [
      for (final address in group ? [first, second] : [first])
        Handle(
          address: address,
          service: 'iMessage',
          uniqueAddressAndService: '$address/iMessage',
        ),
    ];
    for (final handle in handles) {
      final query = store
          .box<Handle>()
          .query(
            Handle_.uniqueAddressAndService.equals(
              handle.uniqueAddressAndService,
            ),
          )
          .build();
      try {
        handle.id = query.findFirst()?.id ?? 0;
      } finally {
        query.close();
      }
      store.box<Handle>().put(handle);
    }
    final result = Chat(
      guid: group ? 'iMessage;+;$suffix' : 'iMessage;-;$first',
      chatIdentifier: group ? suffix : first,
      usingHandle: 'mailto:$sender',
      style: group ? 43 : 45,
    );
    if (group) result.cloudGuid = 'opaque-$suffix';
    result.handles.addAll(handles);
    store.box<Chat>().put(result);
    return result;
  }

  Chat select({
    bool group = false,
    List<String>? recipients,
    Set<String> senders = const {sender},
    void Function(Chat, bool)? proof,
    String? expectedChatGuidSha256,
  }) => selectBackendHarnessFixtureChat(
    store: store,
    recipients: recipients ?? (group ? [first, second] : [first]),
    senderHandles: senders,
    requireDependency: proof ?? (_, _) {},
    expectedChatGuidSha256: expectedChatGuidSha256,
  );

  final refused = throwsA(
    isA<BackendHarnessFailure>().having(
      (e) => e.effectNotEntered,
      'effect not entered',
      true,
    ),
  );

  for (final group in [false, true]) {
    test('${group ? 'group' : 'direct'} preflight includes the owned sender', () async {
      chat(group: group);
      final selected = select(group: group);
      final requested = group ? [first, second] : [first];
      final ownedSender = selected.usingHandle!;
      var calls = 0;
      await BackendHarnessFixtures.preflightTargets(
        requested: requested,
        sender: ownedSender,
        lookup: (targets, handle) async {
          calls++;
          expect(targets, [for (final value in requested) 'tel:$value', ownedSender]);
          expect(handle, ownedSender);
          expect(() => targets.add('tel:other'), throwsUnsupportedError);
          return targets.reversed.toList();
        },
      );
      expect(calls, 1);
    });

    test('${group ? 'group' : 'direct'} preflight requires recipients and sender exactly', () async {
      final requested = group ? [first, second] : [first];
      final recipientTargets = [for (final value in requested) 'tel:$value'];
      const ownedSender = 'mailto:$sender';
      for (final response in <List<String>>[
        recipientTargets, // All recipients, but no own-device reflection target.
        [...recipientTargets.skip(1), ownedSender], // Missing recipient.
        [...recipientTargets, 'mailto:other@example.invalid'], // Wrong sender.
        [...recipientTargets, recipientTargets.first], // Duplicate, same count.
        [...recipientTargets, ownedSender, ownedSender], // Extra duplicate.
        [...recipientTargets, ownedSender, 'tel:other'], // Extra target.
      ]) {
        await expectLater(
          BackendHarnessFixtures.preflightTargets(
            requested: requested,
            sender: ownedSender,
            lookup: (_, _) async => response,
          ),
          refused,
        );
      }
    });
  }

  test(
    'direct selection reuses a proven conversation with unrelated messages',
    () {
      final existing = chat();
      for (var i = 0; i < 2; i++) {
        store.box<Message>().put(
          Message(guid: 'unrelated-$i', text: 'kept')..chat.target = existing,
        );
      }
      final checked = <int>[];
      final selected = select(
        proof: (candidate, group) {
          expect(group, false);
          checked.add(candidate.id!);
        },
      );
      expect(selected.id, existing.id);
      expect(checked, [existing.id]);
      expect(store.box<Chat>().count(), 1);
      expect(store.box<Message>().count(), 2);
      expect(
        store.box<Message>().getAll().map((m) => m.text),
        everyElement('kept'),
      );
    },
  );

  test('sender must be a current exact owned handle, without case folding', () {
    chat();
    expect(() => select(senders: {'other@example.invalid'}), refused);
    expect(() => select(senders: {'SENDER@example.invalid'}), refused);
    expect(select(senders: {'mailto:$sender'}).id, isPositive);
  });

  test(
    'restored group requires exact members and its protected dependency',
    () {
      final existing = chat(group: true);
      var calls = 0;
      final selected = select(
        group: true,
        recipients: [second, first],
        proof: (candidate, group) {
          calls++;
          expect(group, true);
          expect(candidate.id, existing.id);
        },
      );
      expect(selected.id, existing.id);
      expect(calls, 1);
    },
  );

  test('a route without current dependency proof cannot be selected', () {
    chat();
    expect(
      () => select(
        proof: (_, _) {
          throw StateError('missing or stale protected proof');
        },
      ),
      refused,
    );
    expect(store.box<Chat>().count(), 1);
    expect(store.box<Message>().count(), 0);
  });

  test('unapproved, duplicate, empty and oversized recipient sets refuse', () {
    chat();
    for (final recipients in <List<String>>[
      [],
      [first, first],
      ['+15555550101'],
      [first, second, '+15555550101'],
    ]) {
      expect(() => select(recipients: recipients), refused);
    }
  });

  test('unrelated group members never reach protected-route admission', () {
    final existing = chat(group: true);
    final handle = existing.handles.last..address = '+15555550101';
    store.box<Handle>().put(handle);
    var calls = 0;
    expect(
      () => select(
        group: true,
        proof: (_, _) {
          calls++;
        },
      ),
      refused,
    );
    expect(calls, 0);
  });

  test('two qualified groups refuse instead of choosing an arbitrary row', () {
    chat(group: true, suffix: 'one');
    chat(group: true, suffix: 'two');
    expect(() => select(group: true), refused);
    expect(store.box<Chat>().count(), 2);
  });

  test('an exact parent selects the original among two qualified groups', () {
    final original = chat(group: true, suffix: 'original');
    chat(group: true, suffix: 'other');
    store.box<Message>().put(Message(guid: 'kept', text: 'kept')..chat.target = original);
    final checked = <int>[];
    final selected = select(group: true,
      expectedChatGuidSha256: sha256.convert(utf8.encode(original.guid)).toString(),
      proof: (candidate, group) {
        expect(group, isTrue);
        checked.add(candidate.id!);
      });
    expect(selected.id, original.id);
    expect(checked, [original.id]);
    expect(store.box<Chat>().count(), 2);
    expect(store.box<Message>().getAll().single.chat.targetId, original.id);
    expect(store.box<Message>().getAll().single.text, 'kept');
  });

  test('an exact parent never falls back to a different qualified group', () {
    final original = chat(group: true, suffix: 'original');
    chat(group: true, suffix: 'other');
    final pin = sha256.convert(utf8.encode(original.guid)).toString();
    expect(() => select(group: true, expectedChatGuidSha256: '0' * 64), refused);
    expect(() => select(group: true, expectedChatGuidSha256: pin,
      proof: (_, _) => throw StateError('original dependency no longer valid')), refused);
    expect(() => select(group: true, expectedChatGuidSha256: pin,
      senders: {'other@example.invalid'}), refused);
    expect(store.box<Chat>().count(), 2);
    expect(store.box<Message>().count(), 0);
  });

  test('an exact parent cannot bypass approved members or digest grammar', () {
    final original = chat(group: true);
    final pin = sha256.convert(utf8.encode(original.guid)).toString();
    final member = original.handles.last..address = '+15555550101';
    store.box<Handle>().put(member);
    expect(() => select(group: true, expectedChatGuidSha256: pin), refused);
    for (final value in ['', 'A' * 64, 'g' * 64, '0' * 63]) {
      expect(() => select(group: true, expectedChatGuidSha256: value), refused);
    }
    expect(() => select(expectedChatGuidSha256: pin), refused);
  });

  test('pinned refusal identifies parent, sender, metadata and dependency stages', () {
    final original = chat(group: true);
    final pin = sha256.convert(utf8.encode(original.guid)).toString();
    Matcher code(String expected) => throwsA(isA<BackendHarnessFailure>()
      .having((failure) => failure.code, 'fixed readiness code', expected)
      .having((failure) => failure.effectNotEntered, 'effect not entered', true));
    expect(() => select(group: true, expectedChatGuidSha256: '0' * 64),
      code('backend_group_parent_not_ready'));
    expect(() => select(group: true, expectedChatGuidSha256: pin, senders: {'other@example.invalid'}),
      code('backend_group_sender_not_ready'));
    original.cloudGuid = null;
    store.box<Chat>().put(original);
    expect(() => select(group: true, expectedChatGuidSha256: pin),
      code('backend_group_route_not_ready'));
    original.cloudGuid = 'opaque-existing';
    store.box<Chat>().put(original);
    expect(() => select(group: true, expectedChatGuidSha256: pin,
      proof: (_, _) => throw StateError('private protected proof detail')),
      code('backend_group_dependency_not_ready'));
    expect(store.box<Chat>().count(), 1);
    expect(store.box<Message>().count(), 0);
  });

  test('a stale group cannot hide the one current protected route', () {
    final stale = chat(group: true, suffix: 'stale');
    final current = chat(group: true, suffix: 'current');
    final selected = select(
      group: true,
      proof: (candidate, _) {
        if (candidate.id == stale.id) {
          throw StateError('stale account dependency');
        }
      },
    );
    expect(selected.id, current.id);
  });

  test(
    'a provisional group never substitutes for restored group qualification',
    () {
      final existing = chat(group: true)
        ..guid = '01234567-89AB-4DEF-8123-456789ABCDEF'
        ..chatIdentifier = null
        ..cloudGuid = null;
      store.box<Chat>().put(existing);
      expect(() => select(group: true), refused);
      expect(store.box<Message>().count(), 0);
    },
  );

  test('explicit first group accepts only its persisted fresh provisional route', () {
    final fresh = chat(group: true)
      ..guid = '01234567-89AB-4DEF-8123-456789ABCDEF'
      ..chatIdentifier = null
      ..cloudGuid = null;
    store.box<Chat>().put(fresh);
    expect(() => BackendHarnessFixtures.requireFreshGroup(fresh, [second, first]),
      returnsNormally);
    expect(() => BackendHarnessFixtures.requireFreshGroup(fresh, [first]), refused);
    expect(() => BackendHarnessFixtures.requireFreshGroup(fresh, [first, '+15555550101']), refused);
    expect(store.box<Chat>().count(), 1);
    expect(store.box<Message>().count(), 0);
  });
}
