// Offline three-profile comparison. Only fixed categories and counts leave it.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_group_send_route.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final alphaRoot = Platform.environment['OPENBUBBLES_COMPARE_ALPHA'];
  final canaryRoot = Platform.environment['OPENBUBBLES_COMPARE_CANARY'];
  final windowsRoot = Platform.environment['OPENBUBBLES_COMPARE_WINDOWS'];
  final term = Platform.environment['OPENBUBBLES_NAMED_CHAT_NEEDLE'];
  test(
    'compare exact named group and message identities on qualified copies',
    () async {
      expect(
        [
          alphaRoot,
          canaryRoot,
          windowsRoot,
          term,
        ].every((s) => s != null && s.isNotEmpty),
        isTrue,
      );
      final scratch = Directory(r'C:\Codex\OpenBubblesReview\scratch');
      final copies = <Directory>[];
      final stores = <Store>[];
      final sources = <File, String>{};
      try {
        for (final root in [alphaRoot!, canaryRoot!, windowsRoot!]) {
          final source = File('$root/data.mdb');
          final proof =
              jsonDecode(
                    await File(
                      '$root/capture-qualification.json',
                    ).readAsString(),
                  )
                  as Map;
          final digest = (await sha256.bind(source.openRead()).first)
              .toString();
          expect(proof['stable'], isTrue);
          expect(proof['databaseSha256'], digest);
          sources[source] = digest;
          final copy = await scratch.createTemp('chat-compare-');
          copies.add(copy);
          await source.copy('${copy.path}/data.mdb');
          stores.add(await openStore(directory: copy.path));
        }
        final alpha = stores[0];
        bool named(Chat c) => [
          c.displayName,
          c.title,
          c.apnTitle,
        ].any((v) => v?.toLowerCase().contains(term!.toLowerCase()) ?? false);
        final alphaChats = alpha.box<Chat>().getAll().where(named).toList();
        expect(
          alphaChats,
          hasLength(1),
          reason: 'One exact named source group required',
        );
        final reference = alphaChats.single;
        final expected = alpha
            .box<Message>()
            .getAll()
            .where((m) => m.chat.targetId == reference.id)
            .toList();
        Set<String> aliases(Chat c) => {
          c.guid,
          if (c.chatIdentifier != null) c.chatIdentifier!,
          if (c.cloudGuid != null) c.cloudGuid!,
          ...c.guidRefs,
        }.where((s) => s.isNotEmpty).toSet();
        final refAliases = aliases(reference);
        final results = <Map<String, Object?>>[];
        for (var index = 1; index < stores.length; index++) {
          final store = stores[index];
          final allChats = store.box<Chat>().getAll();
          final counterparts = allChats
              .where(
                (c) =>
                    named(c) || aliases(c).intersection(refAliases).isNotEmpty,
              )
              .toList();
          final allMessages = store.box<Message>().getAll();
          final sends = store.box<CloudSyncLocalSendIntentEntity>().getAll();
          final mutations = store
              .box<CloudSyncLocalMutationIntentEntity>()
              .getAll();
          final messageCheckpoints = store
              .box<CloudSyncCheckpointEntity>()
              .getAll()
              .where(
                (row) =>
                    row.zone == 'messageManateeZone' &&
                    row.persistenceLane ==
                        CloudSyncPersistenceLane.semantic.name,
              )
              .toList();
          Map<String, Object?> groupProof(Chat chat) {
            final route = CloudSyncGroupSendRoute.capture(chat);
            final shape = <String, Object?>{
              'senderPresent': chat.usingHandle?.isNotEmpty == true,
              'routeCaptured': route != null,
              'routeProvisional': route?.provisional,
            };
            if (messageCheckpoints.length != 1) {
              return {...shape, 'status': 'message_scope_not_unique'};
            }
            final checkpoint = messageCheckpoints.single;
            final scope = CloudSyncScope(
              accountFingerprint: checkpoint.accountFingerprint,
              container: checkpoint.container,
              database: checkpoint.database,
              zone: checkpoint.zone,
              streamKind: CloudSyncStreamKind.values.byName(
                checkpoint.streamKind,
              ),
              schemaVersion: checkpoint.schemaVersion,
              persistenceLane: CloudSyncPersistenceLane.semantic,
            );
            // Unsaved probe: production proof reads only its target chat ID.
            // Never stage, bind, submit, or change a real Message here.
            final probe = Message(guid: 'synthetic-unsaved-group-proof');
            probe.chat.targetId = chat.id!;
            try {
              final proof = requireCloudSyncRestoredGroupChatProof(
                store: store,
                messageScope: scope,
                message: probe,
              );
              return {
                ...shape,
                'status': 'verified',
                'generation': proof.generation,
              };
            } on CloudSyncFailure catch (failure) {
              return {
                ...shape,
                'status': 'unavailable',
                'code': failure.safeCode,
              };
            }
          }

          final snapshots = store
              .box<CloudSemanticSnapshotEntity>()
              .getAll()
              .where((s) => s.entityKind == 'message')
              .toList();
          var matched = 0;
          var cloudProjected = 0;
          var grouped = 0;
          var duplicates = 0;
          for (final source in expected) {
            if (source.guid == null || source.guid!.isEmpty) continue;
            final matches = allMessages
                .where(
                  (m) => m.guid?.toUpperCase() == source.guid!.toUpperCase(),
                )
                .toList();
            if (matches.isEmpty) continue;
            matched++;
            if (matches.length > 1) duplicates++;
            if (matches.any(
              (m) => counterparts.any((c) => c.id == m.chat.targetId),
            )) {
              grouped++;
            }
            final projected = matches.any(
              (message) => snapshots.any((s) {
                final scope = CloudSyncScope(
                  accountFingerprint: s.accountFingerprint,
                  container: s.container,
                  database: s.database,
                  zone: s.zone,
                  streamKind: CloudSyncStreamKind.values.byName(s.streamKind),
                  schemaVersion: s.schemaVersion,
                  persistenceLane: CloudSyncPersistenceLane.semantic,
                );
                return CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
                      scope: scope,
                      generation: s.generation,
                      canonicalGuid: message.guid!,
                    ) ==
                    s.canonicalGuidLookupHash;
              }),
            );
            if (projected) cloudProjected++;
          }
          results.add({
            'profile': index == 1 ? 'canary' : 'windows',
            'candidateChats': counterparts.length,
            'exactAliasMatchingChats': counterparts
                .where((c) => aliases(c).intersection(refAliases).isNotEmpty)
                .length,
            'nameMatchingChats': counterparts.where(named).length,
            'chatShapes': [
              for (final c in counterparts)
                {
                  'localId': c.id,
                  'style': c.style,
                  'guidSameAsAlpha': c.guid == reference.guid,
                  'cloudGuidSameAsAlpha':
                      c.cloudGuid != null && c.cloudGuid == reference.cloudGuid,
                  'chatIdentifierSameAsAlpha':
                      c.chatIdentifier != null &&
                      c.chatIdentifier == reference.chatIdentifier,
                  'guidInAlphaAliases': refAliases.contains(c.guid),
                  'alphaGuidInAliases': aliases(c).contains(reference.guid),
                  'alphaGuidInGuidRefs': c.guidRefs.contains(reference.guid),
                  'alphaGuidEqualsCloudGuid': c.cloudGuid == reference.guid,
                  'alphaGuidEqualsChatIdentifier':
                      c.chatIdentifier == reference.guid,
                  'alphaGuidEqualsRecordId': c.ckRecordId == reference.guid,
                  'isCanonicalGroup': c.guid.startsWith('iMessage;+;'),
                  'messages': allMessages
                      .where((m) => m.chat.targetId == c.id)
                      .length,
                  'fromMeMessages': allMessages
                      .where(
                        (m) => m.chat.targetId == c.id && m.isFromMe == true,
                      )
                      .length,
                  'journaledLocalSends': sends
                      .where(
                        (intent) => allMessages.any(
                          (m) =>
                              m.id == intent.localMessageId &&
                              m.chat.targetId == c.id,
                        ),
                      )
                      .length,
                  'adoptedLocalSends': sends
                      .where(
                        (intent) =>
                            intent.admittedOperationId != null &&
                            allMessages.any(
                              (m) =>
                                  m.id == intent.localMessageId &&
                                  m.chat.targetId == c.id,
                            ),
                      )
                      .length,
                  'localMutationIntents': mutations
                      .where((intent) => intent.localChatId == c.id)
                      .length,
                  'hasCloudData': c.cloudData?.isNotEmpty == true,
                  'protectedGroupProof': groupProof(c),
                },
            ],
            'linkedMessages': allMessages
                .where((m) => counterparts.any((c) => c.id == m.chat.targetId))
                .length,
            'alphaMessageIdsPresent': matched,
            'alphaMessageIdsCloudProjected': cloudProjected,
            'alphaMessagesLinkedToCandidate': grouped,
            'duplicateMessageIds': duplicates,
          });
        }
        for (final entry in sources.entries) {
          expect(
            (await sha256.bind(entry.key.openRead()).first).toString(),
            entry.value,
          );
        }
        // ignore: avoid_print
        print(
          'CHAT_COMPARISON=${jsonEncode({'sourceUnchanged': true, 'remoteCalls': 0, 'alphaMessages': expected.length, 'alphaMessagesWithGuid': expected.where((m) => m.guid?.isNotEmpty == true).length, 'alphaMessagesWithCloudRecordId': expected.where((m) => m.ckRecordId?.isNotEmpty == true).length, 'alphaMessagesFlaggedCloudSynced': expected.where((m) => m.ckSyncState).length, 'alphaChatCloudMapped': reference.ckRecordId != null, 'comparisons': results})}',
        );
      } finally {
        for (final store in stores) {
          store.close();
        }
        for (final copy in copies) {
          if (copy.parent.absolute.path != scratch.absolute.path ||
              !copy.path
                  .split(Platform.pathSeparator)
                  .last
                  .startsWith('chat-compare-')) {
            throw StateError('chat_comparison_cleanup_target_invalid');
          }
          await copy.delete(recursive: true);
        }
      }
    },
    skip: alphaRoot == null,
  );
}
