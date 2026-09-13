import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/extension_service.dart';
import 'package:flutter_test/flutter_test.dart';

Message _sessionMessage(String session, String key, int second) => Message(
      guid: 'ext-cache-$session-$key',
      amkSessionId: session,
      dateCreated: DateTime.utc(2026, 9, 13, 0, 0, second),
      isFromMe: true,
    );

Future<Store> _openTempStore(String prefix, List<Directory> dirs) async {
  final dir = await Directory('${Directory.current.path}/.dart_tool')
      .createTemp(prefix);
  dirs.add(dir);
  return openStore(directory: dir.path);
}

/// Polls getLatest until the committed rows are visible, then returns them so
/// the caller can assert the refreshed cache with a meaningful failure.
Future<List<String?>> _awaitLatest(
  ExtensionService service,
  String session,
  List<String> expected,
) async {
  for (var i = 0; i < 200; i++) {
    final latest = service.getLatest(session);
    if (latest.join(',') == expected.join(',')) return latest;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return service.getLatest(session);
}

void main() {
  late List<Directory> dirs;
  late List<Store> stores;

  setUp(() {
    dirs = [];
    stores = [];
  });

  tearDown(() async {
    for (final store in stores) {
      if (!store.isClosed()) store.close();
    }
    for (final dir in dirs) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test('insert after first read refreshes the cached session head', () async {
    Store activeStore = await _openTempStore('extension-cache-insert-', dirs);
    stores.add(activeStore);
    final service = ExtensionService(
      storeProvider: () => activeStore,
      messageBoxProvider: () => activeStore.box<Message>(),
    );
    addTearDown(service.onClose);

    const session = 'session-insert';
    activeStore.box<Message>().put(_sessionMessage(session, 'old', 1));
    expect(service.getLatest(session), ['ext-cache-session-insert-old']);

    activeStore.box<Message>().put(_sessionMessage(session, 'new', 2));
    expect(
      await _awaitLatest(
          service, session, ['ext-cache-session-insert-new', 'ext-cache-session-insert-old']),
      ['ext-cache-session-insert-new', 'ext-cache-session-insert-old'],
    );
  });

  test('amkSessionId update moves the cached head', () async {
    Store activeStore = await _openTempStore('extension-cache-update-', dirs);
    stores.add(activeStore);
    final service = ExtensionService(
      storeProvider: () => activeStore,
      messageBoxProvider: () => activeStore.box<Message>(),
    );
    addTearDown(service.onClose);

    const before = 'session-update-before';
    const after = 'session-update-after';
    final message = _sessionMessage(before, 'v1', 3);
    activeStore.box<Message>().put(message);
    expect(service.getLatest(before), ['ext-cache-session-update-before-v1']);

    message.amkSessionId = after;
    activeStore.box<Message>().put(message);
    activeStore
        .box<Message>()
        .put(_sessionMessage(after, 'v2', 4));
    expect(
      await _awaitLatest(service, after, [
        'ext-cache-session-update-after-v2',
        'ext-cache-session-update-before-v1'
      ]),
      [
        'ext-cache-session-update-after-v2',
        'ext-cache-session-update-before-v1'
      ],
    );
    expect(await _awaitLatest(service, before, []), isEmpty);
  });

  test('delete drops the cached head', () async {
    Store activeStore = await _openTempStore('extension-cache-delete-', dirs);
    stores.add(activeStore);
    final service = ExtensionService(
      storeProvider: () => activeStore,
      messageBoxProvider: () => activeStore.box<Message>(),
    );
    addTearDown(service.onClose);

    const session = 'session-delete';
    final box = activeStore.box<Message>();
    box.put(_sessionMessage(session, 'keep', 5));
    final removeId =
        box.put(_sessionMessage(session, 'remove', 6));
    expect(service.getLatest(session),
        ['ext-cache-session-delete-remove', 'ext-cache-session-delete-keep']);

    box.remove(removeId);
    expect(
      await _awaitLatest(service, session, ['ext-cache-session-delete-keep']),
      ['ext-cache-session-delete-keep'],
    );
  });

  test('session head keeps limit-3 newest-first ordering', () async {
    Store activeStore = await _openTempStore('extension-cache-limit-', dirs);
    stores.add(activeStore);
    final service = ExtensionService(
      storeProvider: () => activeStore,
      messageBoxProvider: () => activeStore.box<Message>(),
    );
    addTearDown(service.onClose);

    const session = 'session-limit';
    final box = activeStore.box<Message>();
    for (var second = 1; second <= 5; second++) {
      box.put(_sessionMessage(session, 'm$second', second));
    }
    expect(service.getLatest(session), [
      'ext-cache-session-limit-m5',
      'ext-cache-session-limit-m4',
      'ext-cache-session-limit-m3',
    ]);
  });

  test('store replacement rebinds and drops old heads', () async {
    Store activeStore =
        await _openTempStore('extension-cache-rebind-a-', dirs);
    stores.add(activeStore);
    final secondStore =
        await _openTempStore('extension-cache-rebind-b-', dirs);
    stores.add(secondStore);
    final service = ExtensionService(
      storeProvider: () => activeStore,
      messageBoxProvider: () => activeStore.box<Message>(),
    );
    addTearDown(service.onClose);

    const session = 'session-rebind';
    activeStore.box<Message>().put(_sessionMessage(session, 'a-one', 1));
    expect(service.getLatest(session), ['ext-cache-session-rebind-a-one']);

    secondStore.box<Message>().put(_sessionMessage(session, 'b-one', 2));
    activeStore = secondStore;
    expect(service.getLatest(session), ['ext-cache-session-rebind-b-one']);

    secondStore.box<Message>().put(_sessionMessage(session, 'b-two', 3));
    expect(
      await _awaitLatest(service, session, [
        'ext-cache-session-rebind-b-two',
        'ext-cache-session-rebind-b-one'
      ]),
      [
        'ext-cache-session-rebind-b-two',
        'ext-cache-session-rebind-b-one'
      ],
    );

    stores.first.box<Message>().put(_sessionMessage(session, 'a-two', 9));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(service.getLatest(session), [
      'ext-cache-session-rebind-b-two',
      'ext-cache-session-rebind-b-one'
    ]);
  });

  test('unavailable store fails explicitly instead of serving stale heads',
      () async {
    Store? activeStore =
        await _openTempStore('extension-cache-missing-', dirs);
    stores.add(activeStore);
    final service = ExtensionService(
      storeProvider: () =>
          activeStore ?? (throw StateError('message store missing')),
      messageBoxProvider: () => activeStore!.box<Message>(),
    );
    addTearDown(service.onClose);

    const session = 'session-missing';
    activeStore.box<Message>().put(_sessionMessage(session, 'v1', 1));
    expect(service.getLatest(session), ['ext-cache-session-missing-v1']);

    activeStore = null;
    expect(() => service.getLatest(session), throwsStateError);
    expect(service.amkToLatest, isEmpty);
  });

  test('closed store fails explicitly instead of serving stale heads',
      () async {
    Store activeStore = await _openTempStore('extension-cache-closed-', dirs);
    stores.add(activeStore);
    final service = ExtensionService(
      storeProvider: () => activeStore,
      messageBoxProvider: () => activeStore.box<Message>(),
    );
    addTearDown(service.onClose);

    const session = 'session-closed-store';
    activeStore.box<Message>().put(_sessionMessage(session, 'v1', 1));
    expect(service.getLatest(session),
        ['ext-cache-session-closed-store-v1']);

    activeStore.close();
    expect(() => service.getLatest(session), throwsStateError);
    expect(service.amkToLatest, isEmpty);
  });

  test('closed service fails explicitly and never resubscribes', () async {
    Store activeStore =
        await _openTempStore('extension-cache-close-', dirs);
    stores.add(activeStore);
    final service = ExtensionService(
      storeProvider: () => activeStore,
      messageBoxProvider: () => activeStore.box<Message>(),
    );

    const session = 'session-closed-service';
    activeStore.box<Message>().put(_sessionMessage(session, 'v1', 1));
    expect(service.getLatest(session),
        ['ext-cache-session-closed-service-v1']);

    service.onClose();
    expect(service.amkToLatest, isEmpty);
    expect(() => service.getLatest(session), throwsStateError);

    activeStore.box<Message>().put(_sessionMessage(session, 'v2', 2));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(() => service.getLatest(session), throwsStateError);
    expect(service.amkToLatest, isEmpty);
  });
}
