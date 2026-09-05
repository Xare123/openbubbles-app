import 'dart:convert';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Read one already-known local Chat row without source evaluation, Apple
/// calls, or database writes. Deliberately never prints routing identifiers.
Future<void> main(List<String> args) async {
  if (args.length != 2 || int.tryParse(args[1]) == null) {
    throw ArgumentError('usage: vm_read_canary_chat.dart <ws-uri> <chat-id>');
  }
  final chatId = int.parse(args[1]);
  if (chatId <= 0) throw ArgumentError('chat_id_invalid');
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
        final identifier = fields['chatIdentifier']?.valueAsString;
        print(
          jsonEncode({
            'found': true,
            'localChatId': fields['id']?.valueAsString,
            'guidShape': RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(guid)
                ? 'provisional-uuid'
                : guid.startsWith('iMessage;-;')
                ? 'canonical-direct'
                : 'other',
            'chatIdentifierNull': fields['chatIdentifier']?.kind == 'Null',
            'style': fields['style']?.valueAsString,
            'canonicalGuidMatchesIdentifier':
                identifier != null && guid == 'iMessage;-;$identifier',
            'usingHandlePresent':
                fields['usingHandle']?.valueAsString?.isNotEmpty == true,
            'hasCloudRecord':
                fields['ckRecordId'] != null &&
                fields['ckRecordId']!.kind != 'Null',
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
