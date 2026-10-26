import 'dart:convert';

import 'package:bluebubbles/backend_harness/backend_harness_controller.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_exact_message_reader.dart';
import 'package:flutter_test/flutter_test.dart';

const _guid = '01234567-89AB-CDEF-0123-456789ABCDEF';
const _private = 'PRIVATE credential=secret selector=$_guid record=private-record';

Map<String, Object?> _request(String id, String action,
        Map<String, Object?> arguments) =>
    {'protocol': 1, 'requestId': id, 'action': action, 'arguments': arguments};

BackendHarnessEngine _engine(BackendHarnessOperation operation) =>
    BackendHarnessEngine(
      enabled: true,
      source: 'a' * 40,
      package: 'com.bluebubbles.messaging.backendtest',
      platform: 'android',
      operations: {'fixture.fetch': operation},
    );

Future<Map<String, Object?>> _run(
    Future<CloudSyncExactMessageReadDisposition> Function(String) fetch) async {
  final engine = _engine(backendHarnessExactReadOperation(
    fetch: fetch,
    snapshot: () => const BackendHarnessPayload(),
  ));
  final command = _request('fetch', 'fixture.fetch', {'messageGuid': _guid});
  final accepted = await engine.execute(command);
  expect(accepted['code'], 'backend_job_accepted');
  await engine.closeAdmissionAndDrain();
  return engine.execute(_request('poll', 'job.status', {'jobId': accepted['jobId']}));
}

void main() {
  test('known exact-reader and preflight guards retain closed distinctions on wire', () async {
    const cases = {
      'cloud_sync_exact_read_disabled': 'backend_disabled',
      'cloud_sync_semantic_pull_disabled': 'backend_disabled',
      'cloud_sync_canary_package_required': 'backend_disabled',
      'cloud_sync_exact_read_busy': 'backend_busy',
      'cloud_sync_semantic_pull_active': 'backend_busy',
      'cloud_sync_v2_pcs_preparation_active': 'backend_busy',
      'cloud_sync_v2_pcs_preparation_quiescing': 'backend_busy',
      'coordinator_active': 'backend_busy',
      'cloud_sync_exact_read_identity_changed': 'backend_identity_changed',
      'cloud_sync_v2_pcs_account_changed': 'backend_identity_changed',
      'account_changed': 'backend_identity_changed',
      'logout_active': 'backend_identity_changed',
      'unsupported_platform': 'backend_not_supported',
      'account_unavailable': 'backend_read_auth_failed',
      'cloud_sync_exact_read_archive_enabled': 'backend_exact_read_archive_enabled',
      'cloud_sync_exact_read_cancelled': 'backend_exact_read_cancelled',
      'cloud_sync_exact_read_checkpoint_changed': 'backend_exact_read_checkpoint_changed',
      'cloud_sync_exact_read_record_mismatch': 'backend_exact_read_record_mismatch',
      'cloud_sync_exact_read_outbox_unsettled': 'backend_exact_read_outbox_unsettled',
      'outbox_not_empty': 'backend_exact_read_outbox_unsettled',
      'cloud_sync_semantic_remote_write_tripwire': 'backend_exact_read_tripwire_failed',
      'not_ui_isolate': 'backend_exact_read_ui_required',
      'cloud_sync_v2_pcs_ui_required': 'backend_exact_read_ui_required',
      'rustpush_not_ready': 'backend_exact_read_rustpush_not_ready',
      'objectbox_not_ready': 'backend_exact_read_objectbox_not_ready',
      'storage_unavailable': 'backend_exact_read_storage_unavailable',
      'legacy_sync_active': 'backend_exact_read_legacy_sync_active',
      'protector_unavailable': 'backend_exact_read_protector_unavailable',
      'cloud_sync_v2_pcs_preparation_unavailable': 'backend_exact_read_pcs_unavailable',
      'cloud_sync_v2_pcs_client_unavailable': 'backend_exact_read_pcs_unavailable',
    };
    for (final entry in cases.entries) {
      final result = await _run((guid) async {
        expect(guid, _guid);
        throw StateError(entry.key);
      });
      expect(result['code'], entry.value, reason: entry.key);
      expect(backendHarnessCodes, contains(result['code']));
      expect(result['state'], 'blocked');
      expect(result['ok'], false);
      expect(result['data'], {
        'phase': 'error',
        'flags': {'outcome_uncertain': false},
        'counts': <String, int>{},
      });
      expect(jsonEncode(result), isNot(contains(jsonEncode(entry.key))));
      expect(jsonEncode(result), isNot(contains(_guid)));
    }
  });

  test('private unknown StateErrors and near matches remain generic failed jobs', () async {
    for (final message in [
      _private,
      'cloud_sync_exact_read_busy\n$_private',
      '$_private cloud_sync_exact_read_busy',
      'cloud_sync_exact_read_busy ',
      'cloud_sync_exact_read_new_guard',
      'protector_unavailable\u0000$_private',
      'Bad state: cloud_sync_exact_read_busy',
    ]) {
      final result = await _run((_) async => throw StateError(message));
      expect(result['code'], 'backend_job_failed');
      expect(result['state'], 'failed');
      expect(result['data'], {
        'phase': 'error',
        'flags': {'outcome_uncertain': false},
        'counts': <String, int>{},
      });
      final wire = jsonEncode(result);
      for (final privateValue in [message, _guid, 'credential', 'selector', 'record']) {
        expect(wire, isNot(contains(privateValue)));
      }
    }
  });

  test('unknown exceptions cannot impersonate a guard or stringify private data', () async {
    final poison = _NeverStringify();
    for (final error in <Object>[
      Exception('cloud_sync_exact_read_busy'),
      ArgumentError(_private),
      const FormatException(_private),
      poison,
    ]) {
      expect(backendHarnessExactReadFailureCode(error), isNull);
      final result = await _run((_) async => throw error);
      expect(result['code'], 'backend_job_failed');
      expect(result['state'], 'failed');
      expect((result['data'] as Map)['flags'], {'outcome_uncertain': false});
      expect(jsonEncode(result), isNot(contains(_private)));
      expect(jsonEncode(result), isNot(contains(_guid)));
    }
    expect(poison.stringified, false);
  });

  test('all exact dispositions keep their existing meaning through the actual handler', () async {
    for (final disposition in CloudSyncExactMessageReadDisposition.values) {
      final result = await _run((guid) async {
        expect(guid, _guid);
        return disposition;
      });
      expect(result['code'], 'backend_job_completed');
      expect(result['state'], 'completed');
      expect((result['data'] as Map)['flags'], {
        'exact_read_found': disposition == CloudSyncExactMessageReadDisposition.projected ||
            disposition == CloudSyncExactMessageReadDisposition.retained,
        'exact_read_projected': disposition == CloudSyncExactMessageReadDisposition.projected,
        'exact_read_absent': disposition == CloudSyncExactMessageReadDisposition.absent,
        'exact_read_unresolved': disposition == CloudSyncExactMessageReadDisposition.unresolved,
        'exact_read_tripwires_intact': true,
      });
      expect(jsonEncode(result), isNot(contains(_guid)));
    }
  });

  test('operation preserves admission validation and snapshot without invoking fetch', () async {
    var calls = 0;
    const snapshot = BackendHarnessPayload(flags: {'sync_active': false});
    final operation = backendHarnessExactReadOperation(
      fetch: (_) async { calls++; return CloudSyncExactMessageReadDisposition.absent; },
      snapshot: () => snapshot,
    );
    expect(operation.background, true);
    expect(operation.uncertainOnFailure, false);
    expect(operation.snapshot!(), same(snapshot));
    final engine = _engine(operation);
    for (final arguments in <Map<String, Object?>>[
      {}, {'messageGuid': _private}, {'messageGuid': _guid, 'extra': true},
    ]) {
      final result = await engine.execute(_request('invalid', 'fixture.fetch', arguments));
      expect(result['code'], 'backend_invalid_arguments');
    }
    expect(calls, 0);
  });
}

class _NeverStringify {
  bool stringified = false;
  @override
  String toString() {
    stringified = true;
    throw StateError(_private);
  }
}
