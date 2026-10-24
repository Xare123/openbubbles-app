import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:crypto/crypto.dart';

// Digests are private expected-proof metadata, never ownership or write grants.
// Use the ordinary wire-handle conversion, without alias or case folding.
String backendFixtureParticipantsSha256(Chat chat) {
  final participants = chat.handles.map(RustPushBBUtils.bbHandleToRust).toSet();
  if (chat.usingHandle != null) {
    participants.add(chat.usingHandle!);
  }
  final ordered = participants.toList()..sort();
  return sha256.convert(utf8.encode(jsonEncode(ordered))).toString();
}

String backendFixtureEditHistorySha256(Message message) => sha256.convert(
  utf8.encode(jsonEncode(_ordered([
    for (final summary in message.messageSummaryInfo) summary.toJson(),
  ]))),
).toString();

Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) {
    return value.map(_ordered).toList();
  }
  return value;
}
