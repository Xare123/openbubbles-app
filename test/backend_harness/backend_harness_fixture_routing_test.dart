import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_fixture_routing.dart';
import 'package:bluebubbles/backend_harness/backend_harness_fixtures.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/database/models.dart';
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
  }) => selectBackendHarnessFixtureChat(
    store: store,
    recipients: recipients ?? (group ? [first, second] : [first]),
    senderHandles: senders,
    requireDependency: proof ?? (_, _) {},
  );

  final refused = throwsA(
    isA<BackendHarnessFailure>().having(
      (e) => e.effectNotEntered,
      'effect not entered',
      true,
    ),
  );

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
