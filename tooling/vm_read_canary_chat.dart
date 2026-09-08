import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Read one already-known local Chat row without source evaluation, Apple
/// calls, or database writes. Deliberately never prints routing identifiers.
///
/// Optional content-free recipient-scope enforcement:
/// `--scope direct` requires a canonical direct shape,
/// `--scope group` requires any non-direct (group) shape, and
/// `--expect-hash <sha256>` requires the SHA-256 of the chat opaque guid
/// string to equal the caller-supplied hash. The guid itself is never
/// printed; only its hash, the scope echo, and boolean match results cross
/// this diagnostic boundary. For a direct chat the guid is the canonical
/// routing string, so the operator precomputes its SHA-256 off-device and
/// passes only the hash. For a group chat the operator supplies an
/// independently derived hash; both reads must match it, so the tool can
/// never trust on first use.
/// ASCII-only lowercase for hex digests. Dart case conversion is
/// locale-independent, but hex comparison must never depend on it.
String _asciiLower(String value) {
  final units = value.codeUnits.map(
    (unit) => unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit,
  );
  return String.fromCharCodes(units);
}

Future<void> main(List<String> args) async {
  if (args.length < 2 || args.length > 6) {
    throw ArgumentError(
      'usage: vm_read_canary_chat.dart <ws-uri> <chat-id> [--scope direct|group] [--expect-hash <sha256>]',
    );
  }
  final chatId = int.tryParse(args[1]);
  if (chatId == null || chatId <= 0) throw ArgumentError('chat_id_invalid');
  String? scope;
  String? expectHash;
  for (var i = 2; i < args.length; i++) {
    if (args[i] == '--scope' && i + 1 < args.length) {
      scope = args[++i];
    } else if (args[i] == '--expect-hash' && i + 1 < args.length) {
      expectHash = _asciiLower(args[++i]);
    } else {
      throw ArgumentError('chat_arg_invalid');
    }
  }
  if (scope != null && scope != 'direct' && scope != 'group') {
    throw ArgumentError('chat_scope_invalid');
  }
  if (scope != null && expectHash == null) {
    throw ArgumentError('chat_hash_required');
  }
  if (expectHash != null &&
      !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectHash)) {
    throw ArgumentError('chat_hash_invalid');
  }
  final service = await vmServiceConnectUri(args[0]);
  try {
    final vm = await service.getVM();
    for (final isolateRef in vm.isolates ?? <IsolateRef>[]) {
      final isolateId = isolateRef.id!;
      final isolate = await service.getIsolate(isolateId);
      for (final libraryRef in isolate.libraries ?? <LibraryRef>[]) {
        if (!(libraryRef.uri ?? '').endsWith('/database/database.dart')) {
          continue;
        }
        final library = await service.getObject(isolateId, libraryRef.id!);
        if (library is! Library) continue;
        final databaseRef = library.classes!
            .where((entry) => entry.name == 'Database')
            .single;
        final database = await service.getObject(isolateId, databaseRef.id!);
        if (database is! Class) continue;
        final chatsRef = database.fields!
            .where((entry) => entry.name == 'chats')
            .single;
        final chats = await service.getObject(isolateId, chatsRef.id!);
        if (chats is! Field || chats.staticValue is! InstanceRef) continue;
        final box = chats.staticValue as InstanceRef;
        // Box.get is a read-only lookup; invoke executes its existing compiled
        // implementation even when a standalone APK lacks a compiler service.
        final result = await service.invoke(isolateId, box.id!, 'get', [
          'objects/int-$chatId',
        ], disableBreakpoints: true);
        if (result is! InstanceRef) {
          throw StateError('chat_lookup_failed');
        }
        if (result.kind == 'Null') {
          print(jsonEncode({'found': false}));
          return;
        }
        final chat = await service.getObject(isolateId, result.id!);
        if (chat is! Instance) throw StateError('chat_instance_unavailable');
        final fields = <String, InstanceRef>{};
        for (final field in chat.fields ?? <BoundField>[]) {
          if (field.value is InstanceRef) {
            fields[field.decl!.name!] = field.value as InstanceRef;
          }
        }
        final guid = fields['guid']?.valueAsString ?? '';
        if (guid.isEmpty) throw StateError('chat_guid_missing');
        final identifier = fields['chatIdentifier']?.valueAsString;
        final canonicalMatch =
            identifier != null && guid == 'iMessage;-;$identifier';
        final guidShape =
            RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
            ).hasMatch(guid)
            ? 'provisional-uuid'
            : guid.startsWith('iMessage;-;')
            ? 'canonical-direct'
            : 'other';
        if (scope == 'direct' && !canonicalMatch) {
          throw StateError('direct_identifier_mismatch');
        }
        final routingHash = sha256.convert(utf8.encode(guid)).toString();
        final Object? scopeMatch = scope == null
            ? null
            : scope == 'direct'
            ? (guidShape == 'canonical-direct' && canonicalMatch)
            : guidShape == 'other';
        final Object? recipientHashMatch = expectHash == null
            ? null
            : routingHash == expectHash;
        if (scopeMatch == false) throw StateError('recipient_scope_mismatch');
        if (recipientHashMatch == false) {
          throw StateError('recipient_hash_mismatch');
        }
        print(
          jsonEncode({
            'found': true,
            'localChatId': fields['id']?.valueAsString,
            'guidShape': guidShape,
            'chatIdentifierNull': fields['chatIdentifier']?.kind == 'Null',
            'style': fields['style']?.valueAsString,
            'canonicalGuidMatchesIdentifier': canonicalMatch,
            'usingHandlePresent':
                fields['usingHandle']?.valueAsString?.isNotEmpty == true,
            'hasCloudRecord':
                fields['ckRecordId'] != null &&
                fields['ckRecordId']!.kind != 'Null',
            'routingHash': routingHash,
            'scope': scope,
            'scopeMatch': scopeMatch,
            'recipientHashMatch': recipientHashMatch,
          }),
        );
        return;
      }
    }
    throw StateError('local_database_unavailable');
  } finally {
    await service.dispose();
  }
}
