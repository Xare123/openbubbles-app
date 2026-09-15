import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/io/cloud_sync_records.dart';
import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_origin.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _marker = 'OPENBUBBLES_OUTBOUND_LEASE_OWNER_REPORT=';

String _fingerprint(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 16);

String _stateKey(int state) => 'state_$state';

final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final _mutationClaimNamePattern = RegExp(
  r'^windows-write-(qualification-[a-z0-9-]+)\.json$',
);

void _increment(Map<String, int> values, String key, [int amount = 1]) {
  values[key] = (values[key] ?? 0) + amount;
}

Map<String, Object?> _summary(Set<String> references, Set<String> present) =>
    <String, Object?>{
      'distinct': references.length,
      'present': references.intersection(present).length,
      'absent': references.difference(present).length,
    };

void main() {
  final enabled =
      Platform.environment['OPENBUBBLES_INSPECT_OUTBOUND_LEASE_OWNERS'] == '1';
  var databaseOpen = false;

  setUpAll(() async {
    if (!enabled) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (_) async => <String, Object?>{
            'appName': 'OpenBubbles Cloud Sync V2 Lease Inspector',
            'packageName': 'com.bluebubbles.cloudsync.leaseinspector',
            'version': '0.0.0',
            'buildNumber': '0',
            'buildSignature': '',
            'installerStore': null,
          },
        );
    fs.configureCloudSyncV2WindowsDevProfile();
    await fs.init(headless: true);
    await Logger.init();
    await Database.init(cloudSyncV2Harness: true);
    databaseOpen = true;
  });

  tearDownAll(() {
    if (databaseOpen && !Database.store.isClosed()) Database.store.close();
  });

  test('classifies imported outbound lease owners without content', () async {
    if (!enabled) return;
    final profile = CloudSyncWindowsDevProfile.requireBootstrapped();
    final store = Database.store;
    final nativeStore = Directory(
      '${profile.path}${Platform.pathSeparator}cloud_sync_v2_native_store',
    );

    final pageLeases = store
        .box<CloudProtectedPageLeaseEntity>()
        .getAll()
        .map((row) => row.leaseReference)
        .toSet();
    final outboxLeases = <String>{};
    final sendRequiredLeases = <String>{};
    final mutationLeases = <String>{};
    final readbackLeases = <String>{};
    final uploadRequiredPlanLeases = <String>{};
    final uploadResultLeases = <String>{};
    final ownerLabels = <String, Set<String>>{};

    void own(String reference, String label) {
      ownerLabels.putIfAbsent(reference, () => <String>{}).add(label);
    }

    final outboxByState = <String, int>{};
    final outboxLeaseByState = <String, int>{};
    final outboxByPayloadVersion = <String, int>{};
    final outboxLeaseByPayloadVersion = <String, int>{};
    final outboxByOperationId = <String, CloudOutboxOperationEntity>{};
    var outboxRows = 0;
    for (final row in store.box<CloudOutboxOperationEntity>().getAll()) {
      outboxRows += 1;
      outboxByOperationId[row.operationId] = row;
      _increment(outboxByState, _stateKey(row.state));
      _increment(outboxByPayloadVersion, 'v${row.payloadVersion}');
      final liveStatus =
          row.state == 0 ||
          row.state == 1 ||
          row.state == 2 ||
          row.state == 3 ||
          row.state == 5;
      final specialChatAudit =
          cloudSyncIsNeverSubmittedChatCreate(row) ||
          cloudSyncIsRetiredUnsubmittedChatCreate(row);
      if ((!liveStatus && !specialChatAudit) ||
          row.protectedLeaseReference == null) {
        continue;
      }
      final reference = row.protectedLeaseReference!;
      outboxLeases.add(reference);
      own(reference, 'outbox:${_stateKey(row.state)}:v${row.payloadVersion}');
      _increment(outboxLeaseByState, _stateKey(row.state));
      _increment(outboxLeaseByPayloadVersion, 'v${row.payloadVersion}');
    }

    final sendsByState = <String, int>{};
    final sendLeaseByState = <String, int>{};
    final sendReleasedReferenceByState = <String, int>{};
    final sendReadbackByState = <String, int>{};
    final sendSourceCompletion = <String, int>{};
    var sendRows = 0;
    for (final row in store.box<CloudSyncLocalSendIntentEntity>().getAll()) {
      sendRows += 1;
      _increment(sendsByState, _stateKey(row.state));
      if (row.confirmedReadbackBindingSha256 != null) {
        _increment(sendReadbackByState, _stateKey(row.state));
      }
      final encoded = row.protectedSourceBinding;
      if (encoded == null) continue;
      final reference = CloudSyncLocalSendSourceBinding.decode(
        encoded,
      ).leaseReference;
      final exactReadback =
          row.state == 2 &&
          row.confirmedReadbackBindingSha256 != null &&
          row.confirmedReadbackBindingSha256 == row.admittedBindingSha256;
      final admitted = row.admittedOperationId == null
          ? null
          : outboxByOperationId[row.admittedOperationId!];
      final releasedConfirmedOutbox =
          admitted != null &&
          admitted.state == 2 &&
          admitted.confirmedAtMs > 0 &&
          admitted.protectedLeaseReference == null &&
          admitted.leaseIdHash == null &&
          admitted.leaseExpiresAtMs == 0;
      final terminalReadbackProof = exactReadback && releasedConfirmedOutbox;
      _increment(
        sendSourceCompletion,
        terminalReadbackProof
            ? 'terminal_readback_proven'
            : exactReadback
            ? 'exact_readback_without_released_outbox'
            : 'readback_incomplete',
      );
      if (terminalReadbackProof) {
        // The durable source binding intentionally remembers the released
        // lease. Its absence is terminal cleanup proof, not a missing owner.
        _increment(sendReleasedReferenceByState, _stateKey(row.state));
      } else {
        sendRequiredLeases.add(reference);
        own(
          reference,
          'local_send:${_stateKey(row.state)}:readback_incomplete',
        );
        _increment(sendLeaseByState, _stateKey(row.state));
      }
    }

    final mutationsByState = <String, int>{};
    final mutationsByStateAndKind = <String, int>{};
    final mutationLeaseByState = <String, int>{};
    final mutationProtectedSources =
        <({int state, String reference, String lease})>[];
    var mutationRows = 0;
    for (final row
        in store.box<CloudSyncLocalMutationIntentEntity>().getAll()) {
      mutationRows += 1;
      _increment(mutationsByState, _stateKey(row.state));
      _increment(
        mutationsByStateAndKind,
        '${_stateKey(row.state)}:${row.kind == 0 ? 'edit' : 'unsend'}',
      );
      if (row.state == 5) continue;
      final reference = validateCloudSyncMutationRow(row).leaseReference;
      final source = validateCloudSyncMutationRow(row);
      mutationProtectedSources.add((
        state: row.state,
        reference: source.protectedReference,
        lease: source.leaseReference,
      ));
      mutationLeases.add(reference);
      own(reference, 'mutation:${_stateKey(row.state)}');
      _increment(mutationLeaseByState, _stateKey(row.state));
    }

    var recordMapRows = 0;
    var recordMapPendingLeaseRows = 0;
    for (final row in store.box<CloudRecordMapEntity>().getAll()) {
      recordMapRows += 1;
      final reference = row.protectedReadbackLeaseReference;
      if (reference == null) continue;
      recordMapPendingLeaseRows += 1;
      readbackLeases.add(reference);
      own(reference, 'record_map_readback');
    }

    final uploadsByState = <String, int>{};
    final uploadPlanByState = <String, int>{};
    final uploadReleasedPlanReferenceByState = <String, int>{};
    final uploadResultByState = <String, int>{};
    final uploadReleasedResultByState = <String, int>{};
    final uploadPlanCompletion = <String, int>{};
    var uploadRows = 0;
    for (final row in store.box<CloudAttachmentUploadEntity>().getAll()) {
      uploadRows += 1;
      _increment(uploadsByState, _stateKey(row.state));
      _increment(uploadPlanByState, _stateKey(row.state));
      final result = row.resultLeaseReference;
      final released =
          result != null &&
          CloudSyncAttachmentUploadJournal.resultLeaseReleasedAfterReadback(
            store,
            row,
          );
      _increment(
        uploadPlanCompletion,
        released ? 'terminal_readback_proven' : 'readback_incomplete',
      );
      if (released) {
        // The journal retains the plan reference after terminal readback, but
        // both native leases must already be released at that point.
        _increment(uploadReleasedPlanReferenceByState, _stateKey(row.state));
      } else {
        uploadRequiredPlanLeases.add(row.planLeaseReference);
        own(
          row.planLeaseReference,
          'upload_plan:${_stateKey(row.state)}:readback_incomplete',
        );
      }
      if (result == null) continue;
      _increment(uploadResultByState, _stateKey(row.state));
      if (released) {
        _increment(uploadReleasedResultByState, _stateKey(row.state));
        continue;
      }
      uploadResultLeases.add(result);
      own(result, 'upload_result:${_stateKey(row.state)}');
    }

    final mutationProtectedFilesByState = <String, int>{};
    final mutationMissingProtectedFilesByState = <String, int>{};
    final mutationEnvelopeLeaseMatchByState = <String, int>{};
    final mutationEnvelopeLeaseMismatchByState = <String, int>{};
    for (final source in mutationProtectedSources) {
      final token = source.reference.substring('obcs2.ref.'.length);
      final file = File(
        '${nativeStore.path}${Platform.pathSeparator}$token.protected',
      );
      final present = file.existsSync();
      _increment(
        present
            ? mutationProtectedFilesByState
            : mutationMissingProtectedFilesByState,
        _stateKey(source.state),
      );
      if (!present) continue;
      final bytes = file.readAsBytesSync();
      final newline = bytes.indexOf(10);
      final leaseToken = source.lease.substring('obcs2.lease.'.length);
      final header = newline < 0
          ? null
          : utf8.decode(bytes.sublist(0, newline), allowMalformed: true);
      final computedToken = base64Url
          .encode(
            sha256.convert(<int>[
              ...utf8.encode(leaseToken),
              0x1f,
              ...bytes,
            ]).bytes,
          )
          .replaceAll('=', '');
      _increment(
        header == 'OBCS2-LEASE:$leaseToken' && computedToken == token
            ? mutationEnvelopeLeaseMatchByState
            : mutationEnvelopeLeaseMismatchByState,
        _stateKey(source.state),
      );
    }

    final claimDirectory = Directory(
      '${profile.path}${Platform.pathSeparator}cloud-sync-v2',
    );
    final claimRequestBySourceSha256 = <String, String>{};
    final duplicateClaimSourceFingerprints = <String>[];
    if (claimDirectory.existsSync()) {
      for (final entity in claimDirectory.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final nameMatch = _mutationClaimNamePattern.firstMatch(name);
        if (nameMatch == null) continue;
        try {
          final decoded = jsonDecode(entity.readAsStringSync());
          if (decoded is! Map<String, Object?> ||
              decoded['purpose'] != 'mutation' ||
              decoded['source_sha256'] is! String ||
              !_digestPattern.hasMatch(decoded['source_sha256']! as String)) {
            continue;
          }
          final sourceSha256 = decoded['source_sha256']! as String;
          final requestId = nameMatch.group(1)!;
          final previous = claimRequestBySourceSha256[sourceSha256];
          if (previous != null && previous != requestId) {
            duplicateClaimSourceFingerprints.add(_fingerprint(sourceSha256));
            continue;
          }
          claimRequestBySourceSha256[sourceSha256] = requestId;
        } catch (_) {
          // Malformed historical evidence is ignored by this read-only report.
        }
      }
    }
    final mutationClaimRows = <Map<String, Object?>>[];
    var mutationClaimUnmatched = 0;
    for (final row
        in store.box<CloudSyncLocalMutationIntentEntity>().getAll()) {
      if (row.state == 5) continue;
      final requestId = claimRequestBySourceSha256[row.sourceSha256];
      if (requestId == null) mutationClaimUnmatched += 1;
      mutationClaimRows.add(<String, Object?>{
        'request': requestId ?? 'unmatched:${_fingerprint(row.sourceSha256)}',
        'state': row.state,
        'kind': row.kind == 0 ? 'edit' : 'unsend',
        'writer_epoch': row.writerEpoch,
        'source_fingerprint': _fingerprint(row.sourceSha256),
      });
    }
    mutationClaimRows.sort(
      (left, right) =>
          (left['request']! as String).compareTo(right['request']! as String),
    );
    final activeLeaseDirectory = Directory(
      '${nativeStore.path}${Platform.pathSeparator}.leases',
    );
    final committedLeaseDirectory = Directory(
      '${nativeStore.path}${Platform.pathSeparator}.committed-leases',
    );
    Set<String> readNativeLeaseReferences(Directory directory, String suffix) {
      if (!directory.existsSync()) return <String>{};
      final pattern = RegExp(
        '^\\.lease-([0-9a-f]{32})\\.${RegExp.escape(suffix)}\$',
      );
      return directory
          .listSync(followLinks: false)
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .map(pattern.firstMatch)
          .whereType<RegExpMatch>()
          .map((match) => 'obcs2.lease.${match.group(1)}')
          .toSet();
    }

    final activeNative = readNativeLeaseReferences(
      activeLeaseDirectory,
      'manifest',
    );
    final committedNative = readNativeLeaseReferences(
      committedLeaseDirectory,
      'receipt',
    );
    final nativePresent = <String>{...activeNative, ...committedNative};
    final outboundAll = <String>{
      ...outboxLeases,
      ...sendRequiredLeases,
      ...mutationLeases,
      ...readbackLeases,
      ...uploadRequiredPlanLeases,
      ...uploadResultLeases,
    };

    final ownerMultiplicity = <String, int>{};
    final absentOwners = <Map<String, Object?>>[];
    for (final entry in ownerLabels.entries) {
      _increment(ownerMultiplicity, 'owners_${entry.value.length}');
      if (!nativePresent.contains(entry.key)) {
        absentOwners.add(<String, Object?>{
          'lease_fingerprint': _fingerprint(entry.key),
          'owners': entry.value.toList()..sort(),
        });
      }
    }
    absentOwners.sort(
      (left, right) => (left['lease_fingerprint']! as String).compareTo(
        right['lease_fingerprint']! as String,
      ),
    );

    final report = <String, Object?>{
      'schema': 1,
      'content_exposed': false,
      'raw_identifiers_exposed': false,
      'native': <String, Object?>{
        'active_manifests': activeNative.length,
        'committed_receipts': committedNative.length,
        'distinct_present': nativePresent.length,
      },
      'writer_authority': store
          .box<CloudKitWriterAuthorityEntity>()
          .getAll()
          .map(
            (row) => <String, Object?>{
              'account_fingerprint': _fingerprint(row.accountFingerprint),
              'container': row.container,
              'database': row.database,
              'owner': row.owner,
              'state': row.state,
              'target_owner': row.targetOwner,
              'epoch': row.epoch,
              'transition_present': row.transitionIdHash != null,
            },
          )
          .toList(growable: false),
      'page_leases': _summary(pageLeases, nativePresent),
      'outbox': <String, Object?>{
        'rows': outboxRows,
        ..._summary(outboxLeases, nativePresent),
        'rows_by_state': outboxByState,
        'lease_rows_by_state': outboxLeaseByState,
        'rows_by_payload_version': outboxByPayloadVersion,
        'lease_rows_by_payload_version': outboxLeaseByPayloadVersion,
      },
      'local_send': <String, Object?>{
        'rows': sendRows,
        'required_lease': _summary(sendRequiredLeases, nativePresent),
        'rows_by_state': sendsByState,
        'required_lease_rows_by_state': sendLeaseByState,
        'released_reference_rows_by_state': sendReleasedReferenceByState,
        'readback_rows_by_state': sendReadbackByState,
        'source_completion': sendSourceCompletion,
      },
      'mutation': <String, Object?>{
        'rows': mutationRows,
        ..._summary(mutationLeases, nativePresent),
        'rows_by_state': mutationsByState,
        'rows_by_state_and_kind': mutationsByStateAndKind,
        'lease_rows_by_state': mutationLeaseByState,
        'protected_files_by_state': mutationProtectedFilesByState,
        'missing_protected_files_by_state':
            mutationMissingProtectedFilesByState,
        'envelope_lease_match_by_state': mutationEnvelopeLeaseMatchByState,
        'envelope_lease_mismatch_by_state':
            mutationEnvelopeLeaseMismatchByState,
        'claim_mapping': <String, Object?>{
          'rows': mutationClaimRows,
          'unmatched': mutationClaimUnmatched,
          'duplicate_source_fingerprints': duplicateClaimSourceFingerprints
            ..sort(),
        },
      },
      'record_map_readback': <String, Object?>{
        'rows': recordMapRows,
        'pending_lease_rows': recordMapPendingLeaseRows,
        ..._summary(readbackLeases, nativePresent),
      },
      'attachment_upload': <String, Object?>{
        'rows': uploadRows,
        'rows_by_state': uploadsByState,
        'required_plan_lease': _summary(
          uploadRequiredPlanLeases,
          nativePresent,
        ),
        'plan_rows_by_state': uploadPlanByState,
        'released_plan_reference_rows_by_state':
            uploadReleasedPlanReferenceByState,
        'result': _summary(uploadResultLeases, nativePresent),
        'result_rows_by_state': uploadResultByState,
        'released_result_rows_by_state': uploadReleasedResultByState,
        'plan_completion': uploadPlanCompletion,
      },
      'outbound_required_distinct': outboundAll.length,
      'outbound_required_absent': outboundAll.difference(nativePresent).length,
      'owner_multiplicity': ownerMultiplicity,
      'absent_owners': absentOwners,
    };
    stdout.writeln('$_marker${jsonEncode(report)}');
    expect(report['content_exposed'], isFalse);
    expect(report['raw_identifiers_exposed'], isFalse);
    expect(
      outboundAll.difference(nativePresent),
      isEmpty,
      reason: 'outbound_required_lease_missing',
    );
    expect(
      mutationMissingProtectedFilesByState,
      isEmpty,
      reason: 'mutation_protected_source_missing',
    );
    expect(
      mutationEnvelopeLeaseMismatchByState,
      isEmpty,
      reason: 'mutation_protected_source_lease_mismatch',
    );
    expect(
      duplicateClaimSourceFingerprints,
      isEmpty,
      reason: 'mutation_claim_source_duplicated',
    );
    expect(
      mutationClaimUnmatched,
      0,
      reason: 'mutation_claim_source_unmatched',
    );
  }, skip: !enabled);
}
