import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' hide Response;
import 'package:tuple/tuple.dart';
import 'package:universal_io/io.dart';
import 'package:bluebubbles/database/database.dart';

ChatsService chats = Get.isRegistered<ChatsService>() ? Get.find<ChatsService>() : Get.put(ChatsService());

class ChatsService extends GetxService {
  static const batchSize = 15;
  int currentCount = 0;
  late final StreamSubscription countSub;

  final RxBool hasChats = false.obs;
  Completer<void> loadedAllChats = Completer();
  final RxBool loadedChatBatch = false.obs;
  final RxList<Chat> chats = <Chat>[].obs;

  bool restoring = false;

  final List<Handle> webCachedHandles = [];

  Future<void>? _visibilityRun;
  Future<void>? _initialLoad;
  bool _visibilityDirty = false;
  bool _visibilityDisposed = false;
  int _visibilityGeneration = 0;
  final Set<String> _visibilityManagedGuids = {};

  @visibleForTesting
  Future<void>? get visibilityReconciliation => _visibilityRun;

  /// A notification is a hint, not a count delta or an insertion-ID cursor.
  /// Keep one scanner; changes during a scan request one more complete pass.
  void _requestVisibilityReconciliation() {
    if (_visibilityDisposed || !ss.settings.finishedSetup.value) return;
    _visibilityDirty = true;
    if (_visibilityRun != null || _initialLoad != null) return;
    final generation = _visibilityGeneration;
    _visibilityRun = Future<void>(() async {
      try {
        while (_visibilityDirty && _visibilityCurrent(generation)) {
          _visibilityDirty = false;
          final seen = <String>{};
          // Ordered pins, remaining pins, then ordinary chats. Each section
          // has a keyset cursor, so no growing OFFSET or full-list find().
          for (var section = 0; section < 3; section++) {
            Chat? after;
            while (_visibilityCurrent(generation)) {
              final page = readVisibilityPage(section, after);
              if (!_visibilityCurrent(generation)) return;
              final known = chats.map((chat) => chat.guid).toSet();
              final additions = <Chat>[];
              for (final chat in page) {
                seen.add(chat.guid);
                if (!known.add(chat.guid)) continue;
                chat.getParticipants();
                chat.title = chat.getTitle();
                ensureVisibilityController(chat);
                additions.add(chat);
              }
              if (additions.isNotEmpty) {
                final next = [...chats, ...additions]..sort(Chat.sort);
                chats.value = next;
                hasChats.value = true;
                loadedChatBatch.value = true;
              }
              // Never hold a query/transaction across a yield.
              if (page.isNotEmpty) await yieldVisibilityPage();
              if (page.length < batchSize) break;
              after = page.last;
            }
          }
          if (!_visibilityCurrent(generation)) return;
          // A changed ordering/eligibility key may have moved behind a cursor.
          // Re-scan before removing anything; keep drafts never admitted here.
          if (!_visibilityDirty) {
            final remaining = chats.where((chat) =>
                !_visibilityManagedGuids.contains(chat.guid) ||
                seen.contains(chat.guid)).toList();
            if (remaining.length != chats.length) chats.value = remaining;
            currentCount = seen.length;
            hasChats.value = chats.isNotEmpty;
            loadedChatBatch.value = true;
            if (!loadedAllChats.isCompleted) loadedAllChats.complete();
            _visibilityManagedGuids.clear();
          }
          _visibilityManagedGuids.addAll(seen);
          await yieldVisibilityPage();
        }
      } catch (_) {
        // Preserve the last published list. A later DB hint or explicit init
        // can retry; never spin on a storage failure or log message content.
        _visibilityDirty = false;
        Logger.warn('Local chat visibility reconciliation failed');
      } finally {
        _visibilityRun = null;
        if (_visibilityDirty && !_visibilityDisposed && _initialLoad == null) {
          _requestVisibilityReconciliation();
        }
      }
    });
  }

  bool _visibilityCurrent(int generation) =>
      !_visibilityDisposed &&
      generation == _visibilityGeneration &&
      _initialLoad == null;

  @protected
  Future<void> yieldVisibilityPage() => Future<void>.delayed(Duration.zero);

  @protected
  void ensureVisibilityController(Chat chat) {
    // createChatController also resets active/alive flags on an existing
    // controller. Lookup first, including controllers for temporarily hidden
    // chats, so neither their identity nor route state changes here.
    if (cm.getChatController(chat.guid) == null) cm.createChatController(chat);
  }

  @protected
  List<Chat> readVisibilityPage(int section, Chat? after) {
    var condition = Chat_.dateDeleted.isNull()
        .and(Chat_.telephonyId.isNull())
        .and(Chat_.isRoutingStub.equals(false).or(Chat_.isRoutingStub.isNull()));
    condition = condition.and(section == 2
        ? Chat_.isPinned.equals(false).or(Chat_.isPinned.isNull())
        : Chat_.isPinned.equals(true).and(section == 0
            ? Chat_.pinIndex.notNull()
            : Chat_.pinIndex.isNull()));
    if (after != null) {
      final date = after.dbOnlyLatestMessageDate;
      final dateTail = date == null
          ? Chat_.dbOnlyLatestMessageDate.isNull().and(Chat_.id.lessThan(after.id!))
          : Chat_.dbOnlyLatestMessageDate.lessThanDate(date)
              .or(Chat_.dbOnlyLatestMessageDate.isNull())
              .or(Chat_.dbOnlyLatestMessageDate.equalsDate(date)
                  .and(Chat_.id.lessThan(after.id!)));
      condition = condition.and(section == 0
          ? Chat_.pinIndex.greaterThan(after.pinIndex!)
              .or(Chat_.pinIndex.equals(after.pinIndex!).and(dateTail))
          : dateTail);
    }
    final builder = Database.chats.query(condition)
      ..backlink(Message_.chat,
          Message_.dateDeleted.isNull().and(Message_.dateCreated.notNull()));
    if (section == 0) builder.order(Chat_.pinIndex);
    final query = (builder
          ..order(Chat_.dbOnlyLatestMessageDate, flags: Order.descending)
          ..order(Chat_.id, flags: Order.descending))
        .build()..limit = batchSize;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  @override
  void onInit() {
    super.onInit();
    if (!kIsWeb) {
      // A Message can make an old Chat eligible without inserting a Chat.
      // Observe both entities without keeping an unclosed watch query alive.
      countSub = Database.store.entityChanges.listen((types) {
        if (types.contains(Chat) || types.contains(Message)) {
          _requestVisibilityReconciliation();
        }
      });
      _requestVisibilityReconciliation();
    } else {
      countSub = WebListeners.newChat.listen((chat) async {
        if (!ss.settings.finishedSetup.value) return;
        await addChat(chat);
      });
    }
  }

  RxList<Handle> suggestedHandles = <Handle>[].obs;

  Future<void> loadChatSuggestions() async {
    if (!Platform.isAndroid) return;
    if (chats.isNotEmpty) return;
    List<String> recents = List<String>.from(await mcs.invokeMethod("recent-contacts"));
    await pushService.initFuture;
    List<String> suggestedHandles = [];
    while (recents.isNotEmpty && suggestedHandles.length < 3) {
      var wantedCount = min(3 - suggestedHandles.length, recents.length);
      List<String> queryList = recents.sublist(0, wantedCount);
      recents = recents.sublist(wantedCount);
      List<String> formattedList = [];
      for (var item in queryList) {
        formattedList.add(await RustPushBBUtils.formatAndAddPrefix(item));
      }
      var handle = await (backend as RustPushBackend).getDefaultHandle();
      suggestedHandles.addAll(await pushService.doValidateTargets(formattedList, handle));
    }
    List<Handle> results = suggestedHandles.map((s) => RustPushBBUtils.rustHandleToBB(s)).toList();
    this.suggestedHandles.value = results;
    Logger.info("response $suggestedHandles");
  }

  Future<void> init({bool force = false}) async {
    if (_visibilityDisposed) return;
    if (kIsWeb) return loadInitialChats(force: force);
    final active = _initialLoad;
    if (active != null) return active;
    _visibilityGeneration++;
    _visibilityDirty = true;
    // Defer entry until the pause is installed. Existing startup behavior is
    // unchanged; only list publication is serialized with local admission.
    return _initialLoad = Future<void>(() async {
      if (!_visibilityDisposed) await loadInitialChats(force: force);
    })
        .whenComplete(() {
      _initialLoad = null;
      _requestVisibilityReconciliation();
    });
  }

  @protected
  Future<void> loadInitialChats({bool force = false}) async {
    if (_visibilityDisposed) return;
    if (!force && !ss.settings.finishedSetup.value) return;
    Logger.info("Fetching chats... ${StackTrace.current}", tag: "ChatBloc");
    currentCount = Chat.count() ?? (await backend.getRemoteService()?.chatCount().catchError((err) {
      Logger.info("Error when fetching chat count!", tag: "ChatBloc");
      return Response(requestOptions: RequestOptions(path: ''));
    }))?.data['data']['total'] ?? 0;
    loadedAllChats = Completer();
    if (currentCount != 0) {
      hasChats.value = true;
    } else {
      loadedChatBatch.value = true;
      loadChatSuggestions();
      return;
    }

    final newChats = <Chat>[];
    final batches = (currentCount < batchSize) ? batchSize : (currentCount / batchSize).ceil();

    for (int i = 0; i < batches; i++) {
      List<Chat> temp;
      if (kIsWeb) {
        temp = await cm.getChats(withLastMessage: true, limit: batchSize, offset: i * batchSize);
      } else {
        temp = await Chat.getChats(limit: batchSize, offset: i * batchSize);
      }

      if (kIsWeb) {
        webCachedHandles.addAll(temp.map((e) => e.participants).flattened.toList());
        final ids = webCachedHandles.map((e) => e.address).toSet();
        webCachedHandles.retainWhere((element) => ids.remove(element.address));
      }

      if (_visibilityDisposed) return;
      for (Chat c in temp) {
        if (kIsWeb || cm.getChatController(c.guid) == null) {
          cm.createChatController(c, active: cm.activeChat?.chat.guid == c.guid);
        }
      }
      newChats.addAll(temp);
      newChats.sort(Chat.sort);
      chats.value = newChats;
      loadedChatBatch.value = true;
    }
    loadChatSuggestions();
    loadedAllChats.complete();
    Logger.info("Finished fetching chats (${chats.length}).", tag: "ChatBloc");
    // update share targets
    if (Platform.isAndroid) {
      StartupTasks.waitForUI().then((_) async {
        for (Chat c in chats.where((e) => !isNullOrEmpty(e.title)).take(4)) {
          await mcs.invokeMethod("push-share-targets", {
            "title": c.title,
            "guid": c.guid,
            "icon": await avatarAsBytes(chat: c, quality: 256),
          });
        }
      });
    }

    if (kIsDesktop && Platform.isWindows) {
      /* ----- IMESSAGE:// HANDLER ----- */
      final _appLinks = AppLinks();
      _appLinks.stringLinkStream.listen((String string) async {
        if (!string.startsWith("imessage://")) return;
        final uri = Uri.tryParse(string
            .replaceFirst("imessage://", "imessage:")
            .replaceFirst("&body=", "?body=")
            .replaceFirst(RegExp(r'/$'), ''));
        if (uri == null) return;

        final address = uri.path;
        final handle = Handle.findOne(addressAndService: Tuple2(address, "iMessage"));
        ns.closeSettings(Get.context!);
        await ns.pushAndRemoveUntil(
          Get.context!,
          ChatCreator(
            initialSelected: [SelectedContact(displayName: handle?.displayName ?? address, address: address)],
            initialText: uri.queryParameters['body'],
          ),
          (route) => route.isFirst,
        );
      });
    }

    // prune older chats and messages
    var c = Database.chats.query(Chat_.dateDeleted.lessThanDate(DateTime.now().subtract(const Duration(days: 30)))).build().find();
    for (var chat in c) {
      Chat.deleteChat(chat);
    }
    var messages = Database.messages.query(Message_.dateDeleted.lessThanDate(DateTime.now().subtract(const Duration(days: 30)))).build().find();
    for (var message in messages) {
      Message.delete(message.guid!);
    }
  }

  @override
  void onClose() {
    _visibilityDisposed = true;
    _visibilityGeneration++;
    _visibilityDirty = false;
    countSub.cancel();
    super.onClose();
  }

  void sort() {
    final ids = chats.map((e) => e.guid).toSet();
    chats.retainWhere((element) => ids.remove(element.guid));
    chats.sort(Chat.sort);
  }

  bool updateChat(Chat updated, {bool shouldSort = false, bool override = false}) {
    final index = chats.indexWhere((e) => updated.guid == e.guid);
    if (index != -1) {
      // delete
      if (updated.isRoutingStub) {
        chats.removeAt(index);
        return true;
      }
      final toUpdate = chats[index];
      // this is so the list doesn't re-render
      // ignore: invalid_use_of_protected_member
      chats.value[index] = override ? updated : updated.merge(toUpdate);
      if (shouldSort) sort();
    }

    return index != -1;
  }

  Future<void> addChat(Chat toAdd) async {
    if (toAdd.isRoutingStub) return;
    chats.add(toAdd);
    cm.createChatController(toAdd);
    sort();
  }

  void removeChat(Chat toRemove) {
    final index = chats.indexWhere((e) => toRemove.guid == e.guid);
    chats.removeAt(index);
  }

  void markAllAsRead() {
    final _chats = Database.chats.query(Chat_.hasUnreadMessage.equals(true)).build().find();
    for (Chat c in _chats) {
      c.hasUnreadMessage = false;
      mcs.invokeMethod(
        "delete-notification",
        {
          "notification_id": c.id,
          "tag": NotificationsService.NEW_MESSAGE_TAG
        }
      );
      backend.markRead(c, ss.settings.enablePrivateAPI.value && ss.settings.privateMarkChatAsRead.value);
    }
    Database.chats.putMany(_chats);
  }

  void updateChatPinIndex(int oldIndex, int newIndex) {
    final items = chats.bigPinHelper(true);
    final item = items[oldIndex];

    // Remove the item at the old index, and re-add it at the newIndex
    // We dynamically subtract 1 from the new index depending on if the newIndex is > the oldIndex
    items.removeAt(oldIndex);
    items.insert(newIndex + (oldIndex < newIndex ? -1 : 0), item);

    // Move the pinIndex for each of the chats, and save the pinIndex in the DB
    items.forEachIndexed((i, e) {
      e.pinIndex = i;
      e.save(updatePinIndex: true);
    });
    chats.sort(Chat.sort);
  }

  void removePinIndices() {
    chats.bigPinHelper(true).where((e) => e.pinIndex != null).forEach((element) {
      element.pinIndex = null;
      element.save(updatePinIndex: true);
    });
    chats.sort(Chat.sort);
  }
}
