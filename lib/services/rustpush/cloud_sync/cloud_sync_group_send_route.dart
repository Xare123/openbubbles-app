import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

/// Local routing evidence only. This never proves a CloudKit group exists or
/// authorizes creating one. The sender is separate from the other members.
final class CloudSyncGroupSendRoute {
  const CloudSyncGroupSendRoute._({
    required this.chatId,
    required this.guid,
    required this.identifier,
    required this.originalGuid,
    required this.sender,
    required this.members,
    required this.provisional,
  });

  final int chatId;
  final String guid;
  final String? identifier;
  final String? originalGuid;
  final String sender;
  final List<String> members;
  final bool provisional;

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static CloudSyncGroupSendRoute? capture(Chat chat) {
    if (chat.id == null ||
        chat.id! <= 0 ||
        chat.isRpSms ||
        chat.isRoutingStub) {
      return null;
    }
    final sender = _bareHandle(chat.usingHandle);
    final handles = chat.handles.toList(growable: false);
    if (sender == null ||
        handles.isEmpty ||
        handles.any((handle) => handle.service != 'iMessage')) {
      return null;
    }
    final members = <String>[];
    for (final handle in handles) {
      final member = _bareHandle(handle.address);
      if (member == null || member == sender || members.contains(member)) {
        return null;
      }
      members.add(member);
    }
    members.sort();
    final provisional = _uuid.hasMatch(chat.guid);
    if (provisional) {
      if (handles.length < 2 ||
          (chat.style != null && chat.style != 43) ||
          chat.chatIdentifier != null ||
          chat.ckRecordId != null ||
          chat.cloudData != null ||
          (chat.cloudGuid != null && chat.cloudGuid != chat.guid)) {
        return null;
      }
    } else if (chat.style != 43 ||
        !_identifier(chat.chatIdentifier) ||
        chat.guid != 'iMessage;+;${chat.chatIdentifier}') {
      return null;
    }
    return CloudSyncGroupSendRoute._(
      chatId: chat.id!,
      guid: chat.guid,
      identifier: chat.chatIdentifier,
      originalGuid: provisional
          ? chat.guid
          : (_uuid.hasMatch(chat.cloudGuid ?? '') ? chat.cloudGuid : null),
      sender: sender,
      members: List.unmodifiable(members),
      provisional: provisional,
    );
  }

  bool matchesWire(api.MessageInst wire, {required bool usesOriginalGuid}) {
    final conversation = wire.conversation;
    if (_bareHandle(wire.sender) != sender ||
        conversation == null ||
        (conversation.senderGuid != guid &&
            !(usesOriginalGuid &&
                originalGuid != null &&
                conversation.senderGuid == originalGuid))) {
      return false;
    }
    final actual = <String>[];
    for (final raw in conversation.participants) {
      final participant = _bareHandle(raw);
      if (participant == null) return false;
      actual.add(participant);
    }
    actual.sort();
    final expected = [...members, sender]..sort();
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  static bool _identifier(String? value) =>
      value != null &&
      value.isNotEmpty &&
      value.length <= 4096 &&
      value.trim() == value &&
      !value.runes.any((rune) => rune < 0x20 || rune == 0x7f);

  static String? _bareHandle(String? value) {
    if (!_identifier(value)) return null;
    final raw = value!;
    final prefix = raw.contains('@') ? 'mailto:' : 'tel:';
    if (raw.contains(':') && !raw.startsWith(prefix)) return null;
    final bare = raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
    return _identifier(bare) && !bare.contains(':') ? bare : null;
  }

  @override
  String toString() => 'CloudSyncGroupSendRoute(redacted)';
}
