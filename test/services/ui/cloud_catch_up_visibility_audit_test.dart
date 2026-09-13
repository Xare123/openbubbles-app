import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/extensions/extensions.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ForbiddenBackend implements BackendService {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Visibility must not call the backend');
  }
}

final class _ForbiddenNative extends MethodChannelService {
  int calls = 0;

  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) async {
    calls++;
    throw StateError('Visibility must not call native services');
  }
}

final class _ObservedChatsService extends ChatsService {
  final List<String> admitted = [];
  final List<int> pageSizes = [];
  final List<List<String>> publications = [];
  int scans = 0;
  final List<int> queryMicros = [];
  Completer<void>? pageGate;
  bool useRealControllers = false;
  Completer<void>? initialGate;
  int initialLoads = 0;
  List<Chat> initialSnapshot = [];

  @override
  Future<void> loadInitialChats({bool force = false}) async {
    initialLoads++;
    await initialGate?.future;
    // Simulate the existing loader's list replacement, without its startup
    // native integrations/pruning. The real init serialization is exercised.
    this.chats.value = initialSnapshot;
  }

  @override
  void ensureVisibilityController(Chat chat) {
    admitted.add(chat.guid);
    if (useRealControllers) super.ensureVisibilityController(chat);
  }

  @override
  List<Chat> readVisibilityPage(int section, Chat? after) {
    if (section == 0 && after == null) scans++;
    final watch = Stopwatch()..start();
    final result = super.readVisibilityPage(section, after);
    queryMicros.add(watch.elapsedMicroseconds);
    pageSizes.add(result.length);
    return result;
  }

  @override
  Future<void> yieldVisibilityPage() async {
    publications.add(this.chats.map((chat) => chat.guid).toList());
    final gate = pageGate;
    pageGate = null;
    if (gate != null) await gate.future;
    await super.yieldVisibilityPage();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _ObservedChatsService service;

  setUpAll(() async {
    directory = await Directory(
      '${Directory.current.path}/.dart_tool',
    ).createTemp('cloud-visibility-desired-');
    Database.store = await openStore(directory: directory.path);
    Database.chats = Database.store.box<Chat>();
    Database.messages = Database.store.box<Message>();
    Database.attachments = Database.store.box<Attachment>();
    Database.handles = Database.store.box<Handle>();
    Database.contacts = Database.store.box<Contact>();
    ss.settings = Settings();
    ss.settings.finishedSetup.value = true;
  });

  tearDownAll(() async {
    Database.store.close();
    await directory.delete(recursive: true);
  });

  setUp(() {
    // Only this suite's synthetic database.
    Database.messages.removeAll();
    Database.chats.removeAll();
    ss.settings.filterUnknownSenders.value = false;
    service = _ObservedChatsService();
    service.onInit();
  });

  tearDown(() async {
    service.onClose();
    await service.visibilityReconciliation;
  });

  Future<void> settle() async {
    // ObjectBox entity notifications arrive asynchronously. Wait for them,
    // then join every coalesced pass including a dirty-again continuation.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    while (service.visibilityReconciliation != null) {
      await service.visibilityReconciliation;
    }
  }

  Future<void> until(bool Function() ready) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!ready() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ready(), isTrue);
  }

  Chat seed(
    String guid, {
    bool withMessage = true,
    int day = 1,
    bool pinned = false,
    int? pinIndex,
    bool cacheDate = true,
  }) {
    final chat = Chat(guid: guid, isPinned: pinned, pinnedIndex: pinIndex);
    Database.chats.put(chat);
    if (withMessage) projectMessage(chat, day, cacheDate: cacheDate);
    return chat;
  }

  List<String> visible() => service.chats.map((chat) => chat.guid).toList();

  test(
    'admits zero-to-positive usable chats without explicit reload',
    () async {
      await settle();
      Database.store.runInTransaction(TxMode.write, () {
        seed('first', day: 2);
        seed('second', day: 3);
      });
      await settle();
      expect(visible(), ['second', 'first']);
      expect(service.currentCount, 2);
      expect(service.hasChats.value, isTrue);
      expect(service.loadedChatBatch.value, isTrue);
      expect(service.loadedAllChats.isCompleted, isTrue);
    },
  );

  test('admits every batch chat newest first regardless of ID', () async {
    seed('already-visible');
    await settle();
    Database.store.runInTransaction(TxMode.write, () {
      seed('newest-low-id', day: 3);
      seed('older-high-id', day: 2);
    });
    await settle();
    expect(visible(), ['newest-low-id', 'older-high-id', 'already-visible']);
    expect(service.admitted, [
      'already-visible',
      'newest-low-id',
      'older-high-id',
    ]);
  });

  test('message-only commit admits a late eligible lower-ID chat', () async {
    final late = seed('late-parent', withMessage: false);
    seed('already-visible');
    await settle();
    projectMessage(late, 3, cacheDate: false); // No Chat write.
    await settle();
    expect(visible(), ['late-parent', 'already-visible']);
    expect(service.admitted.toSet(), {'late-parent', 'already-visible'});
    expect(service.admitted, hasLength(2));
  });

  test(
    'publishes bounded recent pages and keysets through ties and nulls',
    () async {
      Database.store.runInTransaction(TxMode.write, () {
        for (var i = 0; i < 37; i++) {
          seed('dated-$i', day: i + 1);
        }
        for (var i = 0; i < 18; i++) {
          seed('null-$i', cacheDate: false);
        }
      });
      await settle();
      expect(visible().toSet(), hasLength(55));
      expect(service.admitted.toSet(), hasLength(55));
      expect(
        service.pageSizes.every((size) => size <= ChatsService.batchSize),
        isTrue,
      );
      expect(service.publications.first, [
        for (var i = 36; i >= 22; i--) 'dated-$i',
      ]);
      expect(service.admitted.take(37), [
        for (var i = 36; i >= 0; i--) 'dated-$i',
      ]);
    },
  );

  test(
    'preserves ordered pins ahead of other pins and ordinary recency',
    () async {
      Database.store.runInTransaction(TxMode.write, () {
        seed('ordinary-newest', day: 30);
        seed('pin-unordered', day: 20, pinned: true);
        for (var i = 19; i >= 0; i--) {
          seed('pin-$i', day: i + 1, pinned: true, pinIndex: i);
        }
      });
      await settle();
      expect(visible(), [
        for (var i = 0; i < 20; i++) 'pin-$i',
        'pin-unordered',
        'ordinary-newest',
      ]);
      expect(service.admitted, visible());
    },
  );

  test('excludes deleted, routing, telephony and unusable chats', () async {
    final deleted = seed('deleted')..dateDeleted = DateTime.utc(2026);
    final routing = seed('routing')..isRoutingStub = true;
    final telephony = seed('telephony')..telephonyId = 42;
    Database.chats.putMany([deleted, routing, telephony]);
    seed('empty', withMessage: false);
    final undated = seed('undated', withMessage: false);
    Database.messages.put(
      Message(guid: 'undated-message')..chat.target = undated,
    );
    final deletedMessageChat = seed('deleted-message-chat', withMessage: false);
    Database.messages.put(
      Message(
        guid: 'deleted-message',
        dateCreated: DateTime.utc(2026),
        dateDeleted: DateTime.utc(2026),
      )..chat.target = deletedMessageChat,
    );
    seed('usable');
    await settle();
    expect(visible(), ['usable']);
  });

  test(
    'keeps archive and unknown sender filtering in existing view helpers',
    () async {
      final archived = seed('archived')..isArchived = true;
      final group = seed('group')..style = 43;
      seed('unknown-direct');
      Database.chats.putMany([archived, group]);
      await settle();
      ss.settings.filterUnknownSenders.value = true;
      expect(service.chats.archivedHelper(true).map((c) => c.guid), [
        'archived',
      ]);
      expect(
        service.chats
            .archivedHelper(false)
            .unknownSendersHelper(false)
            .map((c) => c.guid),
        ['group'],
      );
      expect(
        service.chats
            .archivedHelper(false)
            .unknownSendersHelper(true)
            .map((c) => c.guid),
        ['unknown-direct'],
      );
    },
  );

  test(
    'coalesces overlapping notifications, then catches moved/new keys',
    () async {
      await settle();
      final baselineScans = service.scans;
      final gate = Completer<void>();
      service.pageGate = gate;
      final late = seed('late', withMessage: false);
      Database.store.runInTransaction(TxMode.write, () {
        for (var i = 0; i < 31; i++) {
          seed('batch-$i', day: i + 1);
        }
      });
      await until(() => service.chats.length == 15);
      final active = service.visibilityReconciliation;
      projectMessage(late, 50);
      seed('during-page', day: 51);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(identical(service.visibilityReconciliation, active), isTrue);
      expect(service.scans, baselineScans + 1);
      gate.complete();
      await settle();
      expect(visible().take(2), ['during-page', 'late']);
      expect(visible().toSet(), hasLength(33));
      expect(service.admitted, hasLength(33));
      expect(service.scans, greaterThan(baselineScans + 1));
    },
  );

  test(
    'disposal fences the continuation and prevents controller admission',
    () async {
      await settle();
      final gate = Completer<void>();
      service.pageGate = gate;
      Database.store.runInTransaction(TxMode.write, () {
        for (var i = 0; i < 31; i++) {
          seed('dispose-$i', day: i + 1);
        }
      });
      await until(() => service.chats.length == 15);
      final before = visible();
      final reads = service.pageSizes.length;
      service.onClose();
      seed('after-dispose', day: 60);
      gate.complete();
      await settle();
      expect(visible(), before);
      expect(service.admitted, hasLength(15));
      expect(service.pageSizes.length, reads);
    },
  );

  test(
    'stable reconciliation removes lost eligibility but preserves local drafts',
    () async {
      final chat = seed('was-usable');
      final draft = Chat(guid: 'in-memory-draft', textFieldText: 'keep draft');
      service.chats.add(draft);
      await settle();
      chat.isRoutingStub = true;
      Database.chats.put(chat);
      seed('replacement', day: 2); // Same eligible count.
      await settle();
      expect(visible(), ['replacement', 'in-memory-draft']);
      expect(identical(service.chats.last, draft), isTrue);
    },
  );

  test(
    'initial load fences a paused scan and reconciles its stale snapshot',
    () async {
      await settle();
      final scanGate = Completer<void>();
      service.pageGate = scanGate;
      final initialGate = Completer<void>();
      service.initialGate = initialGate;
      addTearDown(() {
        if (!scanGate.isCompleted) scanGate.complete();
        if (!initialGate.isCompleted) initialGate.complete();
      });
      Database.store.runInTransaction(TxMode.write, () {
        for (var i = 0; i < 31; i++) {
          seed('initial-$i', day: i + 1);
        }
      });
      await until(() => service.chats.length == 15);
      final oldRun = service.visibilityReconciliation;
      final load = service.init();
      final duplicateLoad = service.init();
      await until(() => service.initialLoads == 1);
      final reads = service.pageSizes.length;
      seed('during-initial', day: 60);
      scanGate.complete();
      await oldRun;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.pageSizes.length, reads);
      expect(service.initialLoads, 1);
      initialGate.complete();
      await Future.wait([load, duplicateLoad]);
      await settle();
      expect(visible().first, 'during-initial');
      expect(visible().toSet(), hasLength(32));
      expect(service.currentCount, 32);
    },
  );

  test(
    'disposal before queued initial load does not enter it or rescan',
    () async {
      await settle();
      final reads = service.pageSizes.length;
      final load = service.init();
      service.onClose();
      await load;
      await settle();
      expect(service.initialLoads, 0);
      expect(service.pageSizes.length, reads);
    },
  );

  test(
    'recreated service admits existing rows and no-op hints do not republish',
    () async {
      final chat = seed('existing');
      await settle();
      service.onClose();
      await service.visibilityReconciliation;
      service = _ObservedChatsService()..onInit();
      await settle();
      expect(visible(), ['existing']);
      final instance = service.chats.single;
      var emissions = 0;
      final subscription = service.chats.listen((_) => emissions++);
      final baselineScans = service.scans;
      for (var i = 0; i < 10; i++) {
        projectMessage(chat, 1, cacheDate: false);
      }
      await settle();
      expect(service.scans, greaterThan(baselineScans));
      expect(emissions, 0);
      expect(service.admitted, ['existing']);
      expect(identical(service.chats.single, instance), isTrue);
      await subscription.cancel();
    },
  );

  test(
    'real controller admission is read-only and makes no backend or native calls',
    () async {
      service.onClose();
      await service.visibilityReconciliation;
      final chat = seed('no-side-effects');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final originalManager = cm;
      final originalBackend = backend;
      final originalNative = mcs;
      final manager = ChatManager();
      final forbiddenBackend = _ForbiddenBackend();
      final forbiddenNative = _ForbiddenNative();
      cm = manager;
      backend = forbiddenBackend;
      mcs = forbiddenNative;
      var writes = 0;
      final changes = Database.store.entityChanges.listen((_) => writes++);
      service = _ObservedChatsService()..useRealControllers = true;
      try {
        service.onInit();
        await settle();
        final controller = manager.getChatController(chat.guid);
        expect(controller, isNotNull);
        expect(controller!.isActive || controller.isAlive, isFalse);
        expect(visible(), ['no-side-effects']);
        expect(writes, 0);
        expect(forbiddenBackend.calls, 0);
        expect(forbiddenNative.calls, 0);
        expect(
          Database.chats
              .get(chat.id!)!
              .dbOnlyLatestMessageDate
              ?.millisecondsSinceEpoch,
          chat.dbOnlyLatestMessageDate?.millisecondsSinceEpoch,
        );
      } finally {
        await changes.cancel();
        await manager.getChatController(chat.guid)?.sub.cancel();
        cm = originalManager;
        backend = originalBackend;
        mcs = originalNative;
      }
    },
  );

  test(
    '3000 synthetic chats publish bounded pages and yield between them',
    () async {
      await settle();
      service.publications.clear();
      service.queryMicros.clear();
      service.pageSizes.clear();
      Database.store.runInTransaction(TxMode.write, () {
        for (var i = 0; i < 3000; i++) {
          seed('large-$i', day: (i ~/ 3) + 1); // Equal-date boundaries too.
        }
      });
      final watch = Stopwatch()..start();
      await settle();
      watch.stop();
      expect(visible().toSet(), hasLength(3000));
      expect(service.admitted.toSet(), hasLength(3000));
      expect(service.admitted, hasLength(3000));
      expect(service.publications.first.toSet(), {
        for (var i = 2985; i < 3000; i++) 'large-$i',
      });
      expect(
        service.pageSizes.every((size) => size <= ChatsService.batchSize),
        isTrue,
      );
      expect(service.publications.length, greaterThanOrEqualTo(200));
      final maxQuery = service.queryMicros.reduce((a, b) => a > b ? a : b);
      // Diagnostic measurement, not a hardware-dependent performance assertion.
      // ignore: avoid_print
      print(
        'Synthetic 3000-chat reconciliation: ${watch.elapsedMilliseconds} ms; '
        'max chat-page query: $maxQuery us; ${service.pageSizes.length} queries',
      );
    },
  );

  test(
    'reuses a real active lifecycle controller without resetting its flags',
    () async {
      final chat = seed('existing-controller');
      await settle();
      final originalManager = cm;
      final manager = ChatManager();
      cm = manager;
      final controller = manager.createChatController(chat);
      controller.isActive = true;
      controller.isAlive = true;
      manager.activeChat = controller;
      service.chats.clear();
      service.useRealControllers = true;
      // Message notification only: no existing Chat controller async reload.
      projectMessage(chat, 1, cacheDate: false);
      try {
        await settle();
        expect(
          identical(manager.getChatController(chat.guid), controller),
          isTrue,
        );
        expect(identical(manager.activeChat, controller), isTrue);
        expect(controller.isActive && controller.isAlive, isTrue);
        expect(visible(), ['existing-controller']);
      } finally {
        await controller.sub.cancel();
        cm = originalManager;
      }
    },
  );
}

void projectMessage(Chat chat, int day, {bool cacheDate = true}) {
  final date = DateTime.utc(2026, 9, day);
  final query = Database.messages
      .query(Message_.guid.equals('message-${chat.guid}'))
      .build();
  final existing = query.findFirst();
  query.close();
  final message =
      existing ??
      Message(
        guid: 'message-${chat.guid}',
        text: 'synthetic',
        isFromMe: true,
        dateCreated: date,
      );
  message.chat.target = chat;
  Database.messages.put(message);
  if (cacheDate) {
    chat.dbOnlyLatestMessageDate = date;
    Database.chats.put(chat);
  }
}
