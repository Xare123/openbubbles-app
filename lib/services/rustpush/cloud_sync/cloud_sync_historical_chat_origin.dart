import 'dart:convert';

import 'cloud_sync_historical_protected_source_binding.dart';

/// Content-free immutable codec for the outbox localChatOrigin field of one
/// historical create. Carries generation, intent, optional destination chat,
/// source-chat digest and the exact protected source: never an IDS receipt,
/// remote authority, plaintext, or submit-state invention. All failures use
/// one fixed content-free code.
final class CloudSyncHistoricalChatOrigin {
  CloudSyncHistoricalChatOrigin({
    required this.generation,
    required this.intentId,
    required this.localChatId,
    required this.sourceChatGuidSha256,
    required this.source,
    required this.parentPayloadLength,
  }) {
    if (generation < 1 ||
        intentId < 1 ||
        (localChatId != null && localChatId! < 1) ||
        !_digest.hasMatch(sourceChatGuidSha256) ||
        parentPayloadLength < 1 ||
        parentPayloadLength > 2 * 1024 * 1024) {
      throw StateError('cloud_sync_historical_chat_origin_invalid');
    }
  }

  final int generation;
  final int intentId;

  /// Null means no existing destination Chat; otherwise a positive row id.
  final int? localChatId;
  final String sourceChatGuidSha256;
  final CloudSyncHistoricalProtectedSourceBinding source;

  /// Exact staged Chat envelope length, distinct from the Message source size.
  /// Retained so restart observation reopens the original native stage.
  final int parentPayloadLength;

  static final _digest = RegExp(r'^[a-f0-9]{64}$');

  List<Object?> get _fields => <Object?>[
    1,
    'historicalChatOrigin',
    generation,
    intentId,
    localChatId,
    sourceChatGuidSha256,
    source.encode(),
    parentPayloadLength,
  ];

  String encode() => jsonEncode(_fields);

  static CloudSyncHistoricalChatOrigin decode(String encoded) {
    if (encoded.length > 8192) {
      throw StateError('cloud_sync_historical_chat_origin_invalid');
    }
    final dynamic value;
    try {
      value = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_historical_chat_origin_invalid');
    }
    if (value is! List ||
        value.length != 8 ||
        value[0] != 1 ||
        value[1] != 'historicalChatOrigin' ||
        value[2] is! int ||
        value[3] is! int ||
        (value[4] != null && value[4] is! int) ||
        value[5] is! String ||
        value[6] is! String ||
        value[7] is! int) {
      throw StateError('cloud_sync_historical_chat_origin_invalid');
    }
    final result = CloudSyncHistoricalChatOrigin(
      generation: value[2] as int,
      intentId: value[3] as int,
      localChatId: value[4] as int?,
      sourceChatGuidSha256: value[5] as String,
      source: CloudSyncHistoricalProtectedSourceBinding.decode(
        value[6] as String,
      ),
      parentPayloadLength: value[7] as int,
    );
    if (result.encode() != encoded) {
      throw StateError('cloud_sync_historical_chat_origin_invalid');
    }
    return result;
  }

  @override
  String toString() => 'CloudSyncHistoricalChatOrigin(redacted)';
}

/// True when the encoded value carries the historical purpose tag, including
/// malformed historical payloads (which [CloudSyncHistoricalChatOrigin.decode]
/// then rejects strictly). Legacy direct tuples carry an integer generation
/// in the tag position, so they are never recognized as historical;
/// non-JSON and non-list values are never recognized either. Corruption is
/// routed, not swallowed: a true answer means decode ownership, not validity.
bool isCloudSyncHistoricalChatOrigin(String encoded) {
  if (encoded.length > 8192) return false;
  final dynamic value;
  try {
    value = jsonDecode(encoded);
  } on FormatException {
    return false;
  }
  return value is List &&
      value.length >= 2 &&
      value[0] == 1 &&
      value[1] == 'historicalChatOrigin';
}
