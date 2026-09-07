import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

/// Local routing evidence only. This never proves a CloudKit group exists or
/// authorizes creating one. The sender is separate from the other members.
final class CloudSyncGroupSendRoute {
  const CloudSyncGroupSendRoute._({
    required this.chatId,
    required this.guid,
    required this.identifier,
    required this.groupId,
    required this.originalGuid,
    required this.sender,
    required this.members,
    required this.provisional,
  });

  final int chatId;
  final String guid;
  final String? identifier;
  final String? groupId;
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
      final member = _memberIdentity(handle.address);
      if (member == null || member == sender || members.contains(member)) {
        return null;
      }
      members.add(member);
    }
    members.sort(_compareUtf8);
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
      groupId: provisional && chat.cloudGuid == chat.guid
          ? null
          : (_groupIdentifier(chat.cloudGuid) ? chat.cloudGuid : null),
      originalGuid: provisional
          ? chat.guid
          : (_uuid.hasMatch(chat.cloudGuid ?? '') ? chat.cloudGuid : null),
      sender: sender,
      members: List.unmodifiable(members),
      provisional: provisional,
    );
  }

  /// Reproduces the native decoder's content digest for the current local
  /// group route. [groupVersion] comes from the protected semantic snapshot;
  /// local routing is accepted only when the remaining fields hash back to
  /// that same protected value.
  String? routingMetadataDigest({required int? groupVersion}) {
    final currentGroupId = groupId;
    final currentIdentifier = identifier;
    if (provisional ||
        currentGroupId == null ||
        currentIdentifier == null ||
        (groupVersion != null &&
            (groupVersion < 0 || groupVersion > 0xffffffff))) {
      return null;
    }
    final parts = <List<int>>[
      utf8.encode('OpenBubbles Cloud Sync V2 group routing metadata v1\u0000'),
      utf8.encode(guid),
      utf8.encode(currentIdentifier),
      utf8.encode(currentGroupId),
      utf8.encode('iMessage'),
      utf8.encode('43'),
      utf8.encode(groupVersion == null ? 'absent' : 'value:$groupVersion'),
      ...members.map(utf8.encode),
    ];
    final framed = BytesBuilder(copy: false);
    for (final part in parts) {
      final length = ByteData(8)..setUint64(0, part.length, Endian.big);
      framed
        ..add(length.buffer.asUint8List())
        ..add(part);
    }
    return sha256.convert(framed.takeBytes()).toString();
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
      final participant = _memberIdentity(raw);
      if (participant == null) return false;
      actual.add(participant);
    }
    actual.sort(_compareUtf8);
    final expected = [...members, sender]..sort(_compareUtf8);
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

  static bool _groupIdentifier(String? value) =>
      value != null &&
      value.isNotEmpty &&
      utf8.encode(value).length <= 16 * 1024 &&
      !value.contains('\u0000');

  static String? _bareHandle(String? value) {
    if (!_identifier(value)) return null;
    final raw = value!;
    final prefix = raw.contains('@') ? 'mailto:' : 'tel:';
    if (raw.contains(':') && !raw.startsWith(prefix)) return null;
    final bare = raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
    return _identifier(bare) && !bare.contains(':') ? bare : null;
  }

  static final _businessUrn = RegExp(
    r'^urn:biz:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
    r'[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
  );

  static String? _memberIdentity(String? value) {
    final handle = _bareHandle(value);
    if (handle != null) return handle;
    return value != null && _businessUrn.hasMatch(value) ? value : null;
  }

  /// Rust sorts `&str` by UTF-8 bytes. Dart's default String ordering uses
  /// UTF-16 code units, which differs for non-BMP opaque participant IDs.
  static int _compareUtf8(String left, String right) {
    final a = utf8.encode(left);
    final b = utf8.encode(right);
    final limit = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < limit; i++) {
      final compared = a[i].compareTo(b[i]);
      if (compared != 0) return compared;
    }
    return a.length.compareTo(b.length);
  }

  @override
  String toString() => 'CloudSyncGroupSendRoute(redacted)';
}
