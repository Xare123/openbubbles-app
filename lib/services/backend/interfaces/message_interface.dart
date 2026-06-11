import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/services/backend/actions/message_actions.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:get_it/get_it.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';

class MessageInterface {
  static Future<List<Message?>> getMessages() async {
    final isolate = GetIt.I<GlobalIsolate>();

    final stopwatch = Stopwatch()..start();
    final results = await isolate.send<List<Message?>>(
      IsolateRequestType.getMessages,
      input: null,
    );
    stopwatch.stop();
    Logger.info(
        'Fetched ${results.length} messages from CUSTOM ISOLATE in ${stopwatch.elapsedMilliseconds}ms: ${results.map((m) => m?.guid).join(", ")}');
    return results;
  }

  static Future<List<Message>> bulkSaveNewMessages({
    required Map<String, dynamic> data,
    bool hydrateAttachments = true,
  }) async {
    late List<int> messageIds;
    if (isIsolate) {
      messageIds = await MessageActions.bulkSaveNewMessages(data);
    } else {
      messageIds = await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.bulkSaveNewMessages, input: data);
    }

    // Fetch messages by ID using getMany for efficiency
    final messages = Database.messages.getMany(messageIds).whereType<Message>().toList();
    return messages;
  }

  static Future<Message> replaceMessage({
    required String? oldGuid,
    required Map<String, dynamic> newMessageData,
    bool hydrateAttachments = true,
  }) async {
    final data = {
      'oldGuid': oldGuid,
      'newMessageData': newMessageData,
    };

    late int messageId;
    if (isIsolate) {
      messageId = await MessageActions.replaceMessage(data);
    } else {
      messageId = await GetIt.I<GlobalIsolate>().send<int>(IsolateRequestType.replaceMessage, input: data);
    }

    // Fetch message by ID using get
    final message = Database.messages.get(messageId);
    if (message == null) {
      throw Exception('Failed to fetch message with ID $messageId after replace');
    }

    return message;
  }

  static Future<List<Map<String, dynamic>>> fetchAttachmentsAsync({
    required int messageId,
    required String messageGuid,
  }) async {
    final data = {
      'messageId': messageId,
      'messageGuid': messageGuid,
    };

    if (isIsolate) {
      return await MessageActions.fetchAttachmentsAsync(data);
    } else {
      return await GetIt.I<GlobalIsolate>()
          .send<List<Map<String, dynamic>>>(IsolateRequestType.fetchAttachmentsAsync, input: data);
    }
  }

  static Future<Map<String, dynamic>?> getChatAsync({
    required int messageId,
    required String messageGuid,
  }) async {
    final data = {
      'messageId': messageId,
      'messageGuid': messageGuid,
    };

    if (isIsolate) {
      return await MessageActions.getChatAsync(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<Map<String, dynamic>?>(IsolateRequestType.getChatAsync, input: data);
    }
  }

  static Future<void> deleteMessage({
    required String guid,
  }) async {
    final data = {
      'guid': guid,
    };

    if (isIsolate) {
      return await MessageActions.deleteMessage(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<void>(IsolateRequestType.deleteMessage, input: data);
    }
  }

  static Future<void> softDeleteMessage({
    required String guid,
  }) async {
    final data = {
      'guid': guid,
    };

    if (isIsolate) {
      return await MessageActions.softDeleteMessage(data);
    } else {
      return await GetIt.I<GlobalIsolate>().send<void>(IsolateRequestType.softDeleteMessage, input: data);
    }
  }

  static Future<Map<String, dynamic>> fetchAssociatedMessagesAsync({
    required String messageGuid,
    required int? messageId,
    String? threadOriginatorGuid,
  }) async {
    final data = {
      'messageGuid': messageGuid,
      'messageId': messageId,
      'threadOriginatorGuid': threadOriginatorGuid,
    };

    if (isIsolate) {
      return await MessageActions.fetchAssociatedMessagesAsync(data);
    } else {
      return await GetIt.I<GlobalIsolate>()
          .send<Map<String, dynamic>>(IsolateRequestType.fetchAssociatedMessagesAsync, input: data);
    }
  }

  static Future<Message?> saveMessageAsync({
    required Map<String, dynamic> messageData,
    Map<String, dynamic>? chatData,
    required bool updateIsBookmarked,
    required bool updateSendingServiceId,
    bool hydrateAttachments = true,
  }) async {
    final data = {
      'messageData': messageData,
      'chatData': chatData,
      'updateIsBookmarked': updateIsBookmarked,
      'updateSendingServiceId': updateSendingServiceId,
    };

    late int messageId;
    if (isIsolate) {
      messageId = await MessageActions.saveMessageAsync(data);
    } else {
      messageId = await GetIt.I<GlobalIsolate>().send<int>(IsolateRequestType.saveMessageAsync, input: data);
    }

    // Fetch message by ID using get
    final message = Database.messages.get(messageId);
    return message;
  }

  static Future<Message?> findOneAsync({
    String? guid,
    String? associatedMessageGuid,
    bool hydrateAttachments = true,
  }) async {
    final data = {
      'guid': guid,
      'associatedMessageGuid': associatedMessageGuid,
    };

    late int? messageId;
    if (isIsolate) {
      messageId = await MessageActions.findOneAsync(data);
    } else {
      messageId = await GetIt.I<GlobalIsolate>().send<int?>(IsolateRequestType.findOneAsync, input: data);
    }

    if (messageId == null) return null;

    // Fetch message by ID using get
    final message = Database.messages.get(messageId);
    return message;
  }

  static Future<List<Message>> findAsync({
    String? conditionJson,
    bool hydrateAttachments = true,
  }) async {
    final data = {
      'conditionJson': conditionJson,
    };

    late List<int> messageIds;
    if (isIsolate) {
      messageIds = await MessageActions.findAsync(data);
    } else {
      messageIds = await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.findAsync, input: data);
    }

    // Fetch messages by ID using getMany for efficiency
    final messages = Database.messages.getMany(messageIds).whereType<Message>().toList();
    return messages;
  }

  /// Bulk add messages - offloads heavy processing to the isolate
  static Future<List<Message>> bulkAddMessages({
    Map<String, dynamic>? chatData,
    required List<Map<String, dynamic>> messagesData,
    bool checkForLatestMessageText = true,
    bool hydrateAttachments = true,
  }) async {
    late List<int> messageIds;
    final data = {
      'chatData': chatData,
      'messagesData': messagesData,
      'checkForLatestMessageText': checkForLatestMessageText,
    };

    if (isIsolate) {
      messageIds = await MessageActions.bulkAddMessages(data);
    } else {
      messageIds = await GetIt.I<GlobalIsolate>().send<List<int>>(IsolateRequestType.bulkAddMessages, input: data);
    }

    // Fetch messages by ID using getMany for efficiency
    final messages = Database.messages.getMany(messageIds).whereType<Message>().toList();
    return messages;
  }
}
