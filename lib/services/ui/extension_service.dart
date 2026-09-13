

import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bluebubbles/helpers/types/constants.dart' as constants;


class App {
    int appId;
    String store;
    String madridName;
    String madridBundleId;
    AvailableApp? available;

    App({
        required this.appId,
        required this.store,
        required this.madridName,
        required this.madridBundleId,
        this.available,
    });

    factory App.fromMap(Map<String, dynamic> json) => App(
        appId: json["appId"],
        store: json["store"],
        madridName: json["madridName"],
        madridBundleId: json["madridBundleId"],
        available: json["available"] == null ? null : AvailableApp.fromMap(json["available"]),
    );

    Map<String, dynamic> toMap() => {
        "appId": appId,
        "store": store,
        "madridName": madridName,
        "madridBundleId": madridBundleId,
        "available": available?.toMap(),
    };
}

class AvailableApp {
    String name;
    String icon;

    AvailableApp({
        required this.name,
        required this.icon,
    });

    factory AvailableApp.fromMap(Map<String, dynamic> json) => AvailableApp(
        name: json["name"],
        icon: json["icon"],
    );

    Map<String, dynamic> toMap() => {
        "name": name,
        "icon": icon,
    };
}


ExtensionService es = Get.isRegistered<ExtensionService>() ? Get.find<ExtensionService>() : Get.put(ExtensionService());

class ExtensionService extends GetxService {

  ExtensionService({
    Box<Message> Function()? messageBoxProvider,
    Store Function()? storeProvider,
  })  : _messageBoxProvider = messageBoxProvider ?? (() => Database.messages),
        _storeProvider = storeProvider ?? (() => Database.store);

  final Box<Message> Function() _messageBoxProvider;
  final Store Function() _storeProvider;

  StreamSubscription<void>? _messageWatch;
  Store? _watchedStore;
  bool _closed = false;

  Box<Message> get _messageBox => _messageBoxProvider();

  Store? _currentStore() {
    try {
      return _storeProvider();
    } catch (_) {
      return null;
    }
  }

  void _detachMessageWatch() {
    final sub = _messageWatch;
    _messageWatch = null;
    _watchedStore = null;
    if (sub != null) unawaited(sub.cancel());
    // Never serve heads cached from a detached or replaced store.
    amkToLatest.clear();
  }

  /// Lazily observes committed Message changes and drops cached session heads.
  /// Returns the observed store, or null when no usable store is available.
  /// The listener only clears [amkToLatest]; the next [getLatest] re-queries
  /// just that session (limit 3, newest first). No queries, network, or
  /// service initialization happen on the observer callback.
  Store? _ensureMessageWatch() {
    final current = _closed ? null : _currentStore();
    if (current == null || current.isClosed()) {
      _detachMessageWatch();
      return null;
    }
    if (identical(current, _watchedStore) && _messageWatch != null) {
      return current;
    }
    _detachMessageWatch();
    _watchedStore = current;
    try {
      final watched = current;
      _messageWatch = watched.watch<Message>().listen((_) {
        // Ignore events that arrive after a rebind or close.
        if (!identical(_watchedStore, watched)) return;
        amkToLatest.clear();
      });
    } catch (_) {
      _detachMessageWatch();
      return null;
    }
    return current;
  }

  @override
  void onClose() {
    _closed = true;
    _detachMessageWatch();
    super.onClose();
  }

  List<App> cachedStatus = [];

  Map<String, List<String?>> amkToLatest = {};
  List<String> suppressingSessions = [];

  List<String?> getLatest(String amk) {
    if (_closed) {
      throw StateError('ExtensionService is closed');
    }
    if (_ensureMessageWatch() == null) {
      throw StateError('Message store unavailable');
    }
    if (amkToLatest.containsKey(amk)) {
      return amkToLatest[amk]!;
    }

    final query = (_messageBox.query(Message_.amkSessionId.equals(amk))
            ..order(Message_.dateCreated, flags: Order.descending))
          .build();
          query.limit = 3;

      final messages = query.find();
      query.close();
    

    var results = messages.map((i) => i.stagingGuid ?? i.guid).toList();
    amkToLatest[amk] = results;
    return results;
  }

  bool isAppAvailable(int app) {
    return es.cachedStatus.firstWhereOrNull((i) => i.appId == app)?.available != null;
  }

  bool isAppSupported(int app) {
    return cachedStatus.any((a) => a.appId == app);
  }

  String getExtensionBundle(int app) {
    return cachedStatus.firstWhere((a) => a.appId == app).madridBundleId;
  }

  void engageApp(Message data) async {
    var app = data.payloadData!.appData!.first.appId!;
    var myId = cachedStatus.firstWhereOrNull((a) => a.appId == app);
    if (myId == null) return;

    if (myId.available == null) {
      // redirect to store
      launchUrl(Uri.parse(myId.store));
    }

    var payload = data.payloadData!.appData![0];
    var myMap = payload.toNative(null);
    myMap["messageGuid"] = data.guid;
    myMap["userCount"] = data.chat.target!.participants.length + 1;
    await mcs.invokeMethod("extension-template-tap", myMap);
  }

  Future<void> refreshCache() async {
    Logger.debug("Refreshing extension state");
    if (ss.settings.developerEnabled.value) {
      for (var item in ss.settings.developerMode) {
        await addDevExtension(item);
      }
    }
    var result = await mcs.invokeMethod("extension-status");
    if (result == null) return;
    List<dynamic> parsed = json.decode(result);
    cachedStatus = parsed.map((item) => App.fromMap(item)).toList();
    Logger.debug("Extension state refreshed");
  }

  Future<void> addDevExtension(String package) async {
     await mcs.invokeMethod("dev-extension-handler", {
      "serviceName": package
     });
  }

  Future<void> setSuppress(Map<String, dynamic> args) async {
    if (args["suppress"]) {
      if (!suppressingSessions.contains(args["session"])) {
        suppressingSessions.add(args["session"]);
      }
    } else {
      if (suppressingSessions.contains(args["session"])) {
        suppressingSessions.remove(args["session"]);
      }
    }
  }

  Future<void> updateMessage(Map<String, dynamic> args) async {
    var app = cachedStatus.firstWhere((a) => a.appId == args["appId"]);
    var payload = PayloadData(
      type: constants.PayloadType.app,
      appData: [
        iMessageAppData.fromNative(args, app)
      ],
    );

    var old = Message.findOne(guid: args["messageGuid"])!;

    PlatformFile? file;
    if (args["imageBase64"] != null) {
      var decoded = base64Decode(args["imageBase64"]);
      file = PlatformFile(
        name: "jpeg-image.jpeg",
        size: decoded.length,
        bytes: decoded,
      );
    }

    var message = await backend.updateMessage(old.chat.target!, old, payload, file, false, null);
    inq.queue(IncomingItem(
      chat: old.chat.target!,
      message: message,
      type: QueueType.newMessage
    ));
  }

  Future<void> informUpdate(Message message) async {
    var payload = message.payloadData!.appData![0];
    var myMap = payload.toNative(null);
    myMap["messageGuid"] = message.guid;
    await mcs.invokeMethod("message-update-handler", myMap);
  }

  void addMessage(Map<String, dynamic> args) {
    var app = cachedStatus.firstWhere((a) => a.appId == args["appId"]);

    var payload = PayloadData(
      type: constants.PayloadType.app,
      appData: [
        iMessageAppData.fromNative(args, app)
      ],
    );

    PlatformFile? file;
    if (args["imageBase64"] != null) {
      var decoded = base64Decode(args["imageBase64"]);
      file = PlatformFile(
        name: "jpeg-image.jpeg",
        size: decoded.length,
        bytes: decoded,
      );
    }

    cm.activeChat!.controller!.pickedApp.value = (file, payload);
    cm.activeChat!.controller!.triggerTypingIndicator();
    Logger.debug("set");
  }
}
