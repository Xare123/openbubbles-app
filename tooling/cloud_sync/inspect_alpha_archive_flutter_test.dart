// Private offline inventory only. Absence from a local projection is not remote
// absence and this report never authorizes an upload, send, or history rewrite.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'inventory qualified Alpha history without modifying either source',
    () async {
      final sourceRoots = [
        Platform.environment['OPENBUBBLES_COMPARE_ALPHA'],
        Platform.environment['OPENBUBBLES_COMPARE_CANARY'],
      ];
      expect(
        sourceRoots.every((root) => root != null && root.isNotEmpty),
        isTrue,
      );
      final packages = [
        'com.bluebubbles.messaging.alpha',
        'com.bluebubbles.messaging.cloudkitcanary',
      ];
      final scratch = Directory(r'C:\Codex\OpenBubblesReview\scratch');
      final sources = <File, String>{};
      final copies = <Directory>[];
      final stores = <Store>[];
      try {
        for (var index = 0; index < sourceRoots.length; index++) {
          final root = sourceRoots[index]!;
          final proof =
              jsonDecode(
                    await File(
                      '$root/capture-qualification.json',
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          final source = File('$root/data.mdb');
          final digest = (await sha256.bind(source.openRead()).first)
              .toString();
          expect(proof['stable'], isTrue);
          expect(proof['package'], packages[index]);
          expect(proof['bytes'], await source.length());
          for (final key in [
            'databaseSha256',
            'remoteBeforeSha256',
            'remoteAfterSha256',
          ]) {
            expect(proof[key], digest);
          }
          sources[source] = digest;
          final copy = await scratch.createTemp('alpha-archive-inventory-');
          copies.add(copy);
          await source.copy('${copy.path}/data.mdb');
          expect(
            (await sha256.bind(File('${copy.path}/data.mdb').openRead()).first)
                .toString(),
            digest,
          );
          stores.add(await openStore(directory: copy.path));
        }
        final alpha = stores[0];
        final canary = stores[1];
        final projected = canary.runInTransaction(
          TxMode.read,
          () => {
            for (final message in canary.box<Message>().getAll())
              if (message.guid?.isNotEmpty == true) message.guid!: message,
          },
        );
        final report = alpha.runInTransaction(TxMode.read, () {
          final counts = <String, int>{};
          void increment(String key) => counts[key] = (counts[key] ?? 0) + 1;
          final shapes = <String, int>{};
          void shape(String key, bool present) {
            if (present) shapes[key] = (shapes[key] ?? 0) + 1;
          }

          final chats = {
            for (final chat in alpha.box<Chat>().getAll()) chat.id!: chat,
          };
          final messages = alpha.box<Message>().getAll();
          final attachments = alpha.box<Attachment>().getAll();
          final mediaParents = attachments
              .map((a) => a.message.targetId)
              .toSet();
          final sends = alpha.box<CloudSyncLocalSendIntentEntity>().getAll();
          final received = alpha
              .box<CloudSyncReceivedArchiveIntentEntity>()
              .getAll();
          for (final message in messages) {
            final guid = message.guid;
            if (guid == null || guid.isEmpty) {
              increment('missingGuid');
              continue;
            }
            final current = projected[guid];
            if (current != null) {
              increment('alreadyInCanaryProjection');
              if (message.text != current.text ||
                  message.subject != current.subject ||
                  message.dateCreated != current.dateCreated ||
                  message.isFromMe != current.isFromMe ||
                  message.dateEdited != current.dateEdited ||
                  message.dateDeleted != current.dateDeleted) {
                increment('matchingGuidWithDifferentLocalFields');
              }
              continue;
            }
            increment('notInCanaryProjection');
            shape('hasText', message.text?.isNotEmpty == true);
            shape('hasAttributedBody', message.attributedBody.isNotEmpty);
            shape('hasReply', message.threadOriginatorGuid != null);
            shape(
              'hasExtension',
              message.hasApplePayloadData ||
                  message.payloadData != null ||
                  message.balloonBundleId != null ||
                  message.amkSessionId != null,
            );
            shape('missingCreationTime', message.dateCreated == null);
            shape('missingDirection', message.isFromMe == null);
            shape('hasSummary', message.messageSummaryInfo.isNotEmpty);
            shape(
              'hasActualEditOrUnsend',
              message.dateEdited != null ||
                  message.messageSummaryInfo.any(
                    (summary) =>
                        summary.retractedParts.isNotEmpty ||
                        summary.editedParts.isNotEmpty ||
                        summary.editedContent.isNotEmpty,
                  ),
            );
            if (message.ckRecordId != null || message.ckSyncState) {
              increment('unprojectedWithLegacyCloudMarker');
            }
            final chat = chats[message.chat.targetId];
            if (chat == null) {
              increment('missingChat');
            } else if (chat.isRpSms ||
                chat.guid.startsWith('SMS') ||
                chat.guid.startsWith('RCS')) {
              increment('excludedCarrierChat');
            } else if (chat.dateDeleted != null ||
                message.dateDeleted != null) {
              increment('deletedLocallyNeedsTombstoneDisposition');
            } else if (message.guid!.startsWith('temp') ||
                message.guid!.startsWith('error') ||
                message.error != 0 ||
                message.sendingServiceId != null ||
                message.dateScheduled != null ||
                message.verificationFailed) {
              increment('unconfirmedOrScheduledNotArchiveCandidate');
            } else if (message.associatedMessageGuid != null ||
                message.associatedMessageType != null ||
                message.itemType != 0) {
              increment('associationOrSystemNeedsSeparateHandling');
            } else if (message.dateEdited != null ||
                message.messageSummaryInfo.isNotEmpty) {
              increment('summaryOrEditNeedsVersionDisposition');
            } else if (message.hasAttachments ||
                mediaParents.contains(message.id)) {
              increment('mediaNeedsBodyAndMetadataHandling');
            } else if (message.dateCreated == null ||
                message.isFromMe == null ||
                message.text == null ||
                message.text!.isEmpty ||
                message.hasApplePayloadData ||
                message.payloadData != null ||
                message.balloonBundleId != null ||
                message.amkSessionId != null ||
                message.threadOriginatorGuid != null ||
                message.attributedBody.isNotEmpty) {
              increment('textOrRichContentNeedsHistoricalProof');
            } else {
              increment('plainTextNeedsHistoricalAndRemoteProof');
              increment(
                message.isFromMe! ? 'plainTextFromMe' : 'plainTextIncoming',
              );
              if (chat.style == 43) increment('plainTextGroupStyle');
            }
          }
          return {
            'alphaChats': chats.length,
            'alphaMessages': messages.length,
            'alphaAttachments': attachments.length,
            'alphaLocalSendIntents': sends.length,
            'alphaReceivedArchiveIntents': received.length,
            'canaryProjectedMessagesWithGuid': projected.length,
            'counts': counts,
            // Overlapping descriptive counts, never admission or upload proof.
            'unprojectedShapes': shapes,
          };
        });
        for (final source in sources.entries) {
          expect(
            (await sha256.bind(source.key.openRead()).first).toString(),
            source.value,
          );
        }
        // ignore: avoid_print
        print(
          'ALPHA_ARCHIVE_INVENTORY=${jsonEncode({...report, 'sourceUnchanged': true, 'remoteCalls': 0, 'uploads': 0, 'idsSends': 0, 'remoteAbsenceProven': false, 'notAnUploadPlan': true})}',
        );
      } finally {
        for (final store in stores) {
          store.close();
        }
        for (final copy in copies) {
          expect(copy.parent.absolute.path, scratch.absolute.path);
          await copy.delete(recursive: true);
        }
      }
    },
  );
}
