import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/services/backend/actions/chat_actions.dart';
import 'package:bluebubbles/models/models.dart' show MessageSaveResult;
import 'package:bluebubbles/services/services.dart';
import 'package:get_it/get_it.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';

class ChatInterface {
  static Future<void> clearNotificationForChat({
    required int chatId,
    required String chatGuid,
  }) async {
    final data = {
      'chatId': chatId,
      'chatGuid': chatGuid,
    };

    if (isIsolate) {
      return await ChatActions.clearNotificationForChat(data);
    } else if (!LifecycleSvc.isBubble) {
      return await GetIt.I<GlobalIsolate>().send<void>(IsolateRequestType.clearNotificationForChat, input: data);
    }
  }

  static Future<void> markChatReadUnread({
    required String chatGuid,
    required bool markAsRead,
    required bool shouldMarkOnServer,
  }) async {
    final Map<String, dynamic> data = {
      'chatGuid': chatGuid,
      'markAsRead': markAsRead,
      'shouldMarkOnServer': shouldMarkOnServer,
    };

    if (isIsolate) {
      return await ChatActions.markChatReadUnread(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<void>(IsolateRequestType.markChatReadUnread, input: data);
    }
  }

  static Future<int?> saveChat({
    required String guid,
    required Map<String, dynamic> chatData,
    required Map<String, bool> updateFlags,
  }) async {
    final data = {
      'guid': guid,
      'chatData': chatData,
      'updateFlags': updateFlags,
    };

    if (isIsolate) {
      return await ChatActions.saveChat(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<int?>(IsolateRequestType.saveChat, input: data);
    }
  }

  static Future<void> deleteChat({
    required int chatId,
    required List<int> messageIds,
    List<int> handleIds = const [],
  }) async {
    final data = {
      'chatId': chatId,
      'messageIds': messageIds,
      'handleIds': handleIds,
    };

    if (isIsolate) {
      return await ChatActions.deleteChat(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<void>(IsolateRequestType.deleteChat, input: data);
    }
  }

  static Future<void> softDeleteChat({
    required Map<String, dynamic> chatData,
  }) async {
    final data = {
      'chatData': chatData,
    };

    if (isIsolate) {
      return await ChatActions.softDeleteChat(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<void>(IsolateRequestType.softDeleteChat, input: data);
    }
  }

  static Future<void> unDeleteChat({
    required Map<String, dynamic> chatData,
  }) async {
    final data = {
      'chatData': chatData,
    };

    if (isIsolate) {
      return await ChatActions.unDeleteChat(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<void>(IsolateRequestType.unDeleteChat, input: data);
    }
  }

  static Future<MessageSaveResult> addMessageToChat({
    required Map<String, dynamic> messageData,
    required Map<String, dynamic> chatData,
    required Map<String, dynamic> latestMessageData,
    required bool checkForMessageText,
  }) async {
    final data = {
      'messageData': messageData,
      'chatData': chatData,
      'latestMessageData': latestMessageData,
      'checkForMessageText': checkForMessageText,
    };

    late Map<String, dynamic> result;
    if (isIsolate) {
      result = await ChatActions.addMessageToChat(data);
    } else {
      result =
          await GetIt.I<GlobalIsolate>().send<Map<String, dynamic>>(IsolateRequestType.addMessageToChat, input: data);
    }

    final message = Database.messages.get(result['messageId'] as int)!;
    final isNewer = result['isNewer'] as bool;
    return MessageSaveResult(message, isNewer);
  }

  static Future<List<Message>> loadSupplementalData({
    required List<String> messageGuids,
  }) async {
    final data = {
      'messageGuids': messageGuids,
    };

    // Get reaction IDs from isolate
    final reactionIds = isIsolate
        ? await ChatActions.loadSupplementalData(data)
        : await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.loadSupplementalData, input: data);

    // Hydrate the reaction messages on the main thread with proper DB connection
    // This ensures handleRelation and other ToOne relationships are loaded correctly
    if (reactionIds.isEmpty) {
      return <Message>[];
    }

    // Use getMany to load messages with their relationships
    // This automatically loads ToMany relationships like dbAttachments and ToOne like handleRelation
    final reactions = Database.messages.getMany(reactionIds);
    return reactions.whereType<Message>().toList();
  }

  static Future<List<Chat>> syncLatestMessages({required List<String> chatGuids, required bool toggleUnread}) async {
    final data = {
      'chatGuids': chatGuids,
      'toggleUnread': toggleUnread,
    };

    late List<int> chatIds;
    if (isIsolate) {
      chatIds = await ChatActions.syncLatestMessages(data);
    } else {
      chatIds = await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.syncLatestMessages, input: data);
    }

    // Fetch chats by ID using getMany for efficiency
    return Database.chats.getMany(chatIds).whereType<Chat>().toList();
  }

  static Future<({List<Chat> chats, List<int> affectedHandleIds})> bulkSyncChats(
      {required List<Map<String, dynamic>> chatsData}) async {
    final data = {
      'chatsData': chatsData,
    };

    late List<int> chatIds;
    late List<int> affectedHandleIds;
    if (isIsolate) {
      final result = await ChatActions.bulkSyncChats(data);
      chatIds = (result['chatIds'] as List).cast<int>();
      affectedHandleIds = (result['affectedHandleIds'] as List).cast<int>();
    } else {
      final result =
          await GetIt.I<GlobalIsolate>().send<Map<String, dynamic>>(IsolateRequestType.bulkSyncChats, input: data);
      chatIds = (result['chatIds'] as List).cast<int>();
      affectedHandleIds = (result['affectedHandleIds'] as List).cast<int>();
    }

    final chats = Database.chats.getMany(chatIds).whereType<Chat>().toList();
    return (chats: chats, affectedHandleIds: affectedHandleIds);
  }

  static Future<List<Message>> getMessagesAsync({
    required int chatId,
    required String chatGuid,
    required List<Map<String, dynamic>> participantsData,
    int offset = 0,
    int limit = 25,
    bool includeDeleted = false,
    int? searchAround,
    bool hydrateAttachments = true,
  }) async {
    final data = {
      'chatId': chatId,
      'chatGuid': chatGuid,
      'participantsData': participantsData,
      'offset': offset,
      'limit': limit,
      'includeDeleted': includeDeleted,
      'searchAround': searchAround,
    };

    late List<int> messageIds;
    if (isIsolate) {
      messageIds = await ChatActions.getMessagesAsync(data);
    } else {
      messageIds = await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.getMessagesAsync, input: data);
    }

    // Fetch messages by ID using getMany for efficiency
    return Database.messages.getMany(messageIds).whereType<Message>().toList();
  }

  static Future<List<Message>> bulkSyncMessages({
    required Map<String, dynamic> chatData,
    required List<Map<String, dynamic>> messagesData,
    bool hydrateAttachments = true,
  }) async {
    final data = {
      'chatData': chatData,
      'messagesData': messagesData,
    };

    late List<int> messageIds;
    if (isIsolate) {
      messageIds = await ChatActions.bulkSyncMessages(data);
    } else {
      messageIds = await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.bulkSyncMessages, input: data);
    }

    // Fetch messages by ID using getMany for efficiency
    return Database.messages.getMany(messageIds).whereType<Message>().toList();
  }

  static Future<List<Handle>> getParticipantsAsync({
    required int chatId,
    required String chatGuid,
  }) async {
    final data = {
      'chatId': chatId,
      'chatGuid': chatGuid,
    };

    late List<int> handleIds;
    if (isIsolate) {
      handleIds = await ChatActions.getParticipantsAsync(data);
    } else {
      handleIds = await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.getParticipantsAsync, input: data);
    }

    // Fetch handles by ID using getMany for efficiency
    return Database.handles.getMany(handleIds).whereType<Handle>().toList();
  }

  static Future<void> clearTranscriptAsync({
    required int chatId,
    required String chatGuid,
  }) async {
    final data = {
      'chatId': chatId,
      'chatGuid': chatGuid,
    };

    if (isIsolate) {
      return await ChatActions.clearTranscriptAsync(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<void>(IsolateRequestType.clearTranscriptAsync, input: data);
    }
  }

  static Future<List<Chat>> getChatsAsync({
    int limit = 15,
    int offset = 0,
    List<int> ids = const [],
  }) async {
    final data = {
      'limit': limit,
      'offset': offset,
      'ids': ids,
    };

    late List<int> chatIds;
    if (isIsolate) {
      chatIds = await ChatActions.getChatsAsync(data);
    } else {
      chatIds = await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.getChatsAsync, input: data);
    }

    // Fetch chats by ID using getMany for efficiency
    return Database.chats.getMany(chatIds).whereType<Chat>().toList();
  }
}
