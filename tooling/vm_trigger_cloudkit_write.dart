import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const _recipientEnvironment = 'OPENBUBBLES_CANARY_RECIPIENT';
final _guidHashPattern = RegExp(r'^[0-9a-f]{16}$');
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

final class CloudKitWritePreparation {
  const CloudKitWritePreparation({
    required this.candidateFound,
    this.guidHash,
    this.createdAtUtc,
  });

  final bool candidateFound;
  final String? guidHash;
  final String? createdAtUtc;

  Map<String, Object?> toJson() => {
    'mode': 'prepare',
    'candidateFound': candidateFound,
    'guidHash': guidHash,
    'createdAtUtc': createdAtUtc,
  };
}

final class CloudKitWriteResult {
  const CloudKitWriteResult({
    required this.guidHash,
    required this.admitted,
    required this.deferred,
    required this.outboxBlocked,
    required this.chatReadbackPending,
    required this.candidateLimitReached,
  });

  final String guidHash;
  final int admitted;
  final int deferred;
  final bool outboxBlocked;
  final bool chatReadbackPending;
  final bool candidateLimitReached;

  Map<String, Object> toJson({required bool verification}) => {
    'mode': verification ? 'verify' : 'run',
    'guidHash': guidHash,
    'admitted': admitted,
    'deferred': deferred,
    'outboxBlocked': outboxBlocked,
    'chatReadbackPending': chatReadbackPending,
    'candidateLimitReached': candidateLimitReached,
  };
}

String normalizedRecipientSha256(String recipient) {
  var normalized = recipient.trim();
  final lower = normalized.toLowerCase();
  if (lower.startsWith('mailto:')) {
    normalized = normalized.substring('mailto:'.length);
  } else if (lower.startsWith('tel:')) {
    normalized = normalized.substring('tel:'.length);
  }
  normalized = normalized.trim().toLowerCase();
  if (normalized.isEmpty || normalized.length > 320) {
    throw ArgumentError('write_recipient_invalid');
  }
  return sha256.convert(utf8.encode(normalized)).toString();
}

Future<List<String>> _waitForObservation({
  required VmService service,
  required String isolateId,
  required InstanceRef observer,
  required int expectedLength,
  required Set<String> terminalStates,
  required Duration timeout,
}) async {
  final observerId = observer.id;
  if (observerId == null) {
    throw StateError('cloud_sync_write_observer_unavailable');
  }
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    final current = await service.getObject(isolateId, observerId);
    if (current is! Instance || current.elements?.length != expectedLength) {
      throw StateError('cloud_sync_write_observer_invalid');
    }
    final values = <String>[];
    for (final element in current.elements!) {
      if (element is! InstanceRef || element.valueAsString == null) {
        throw StateError('cloud_sync_write_observer_invalid');
      }
      values.add(element.valueAsString!);
    }
    if (terminalStates.contains(values.first)) return values;
    if (values.first != 'pending' ||
        values.skip(1).any((value) => value.isNotEmpty)) {
      throw StateError('cloud_sync_write_observer_invalid');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  // Observation timeout is neither cancellation nor permission to retry.
  throw StateError('cloud_sync_write_operation_still_running');
}

Future<CloudKitWritePreparation> invokePrepareAndSelect({
  required VmService service,
  required String isolateId,
  required String libraryId,
  required String targetId,
  required String recipient,
  Duration timeout = const Duration(seconds: 120),
}) async {
  final recipientLiteral = jsonEncode(recipient);
  final observer = await service.evaluate(
    isolateId,
    libraryId,
    '''
    (() {
      final observation = <String>['pending', '', '', ''];
      Future<void> run() async {
        try {
          await writeTarget.prepareCloudSyncV2OutboundWriter();
          final selected = await writeTarget.selectCloudSyncV2ExactIntent(
            expectedRecipient: $recipientLiteral,
          );
          if (selected == null) {
            observation[0] = 'no_candidate';
            return;
          }
          observation[2] = selected.guidHash;
          observation[3] = selected.createdAtUtc.toIso8601String();
          observation[0] = 'prepared';
        } catch (error) {
          observation[0] = 'failed';
          final candidate = error is StateError ? error.message.toString() : '';
          observation[1] = RegExp(r'^cloud_sync_[a-z0-9_]+\$').hasMatch(candidate)
              ? candidate : 'cloud_sync_write_operation_failed';
        }
      }
      Future<void>(run);
      return observation;
    })()
  ''',
    scope: {'writeTarget': targetId},
    disableBreakpoints: true,
  );
  if (observer is! InstanceRef) {
    throw StateError('cloud_sync_write_observer_unavailable');
  }
  final values = await _waitForObservation(
    service: service,
    isolateId: isolateId,
    observer: observer,
    expectedLength: 4,
    terminalStates: const {'prepared', 'no_candidate', 'failed'},
    timeout: timeout,
  );
  if (values[0] == 'failed') throw StateError(values[1]);
  if (values[0] == 'no_candidate') {
    return const CloudKitWritePreparation(candidateFound: false);
  }
  if (!_guidHashPattern.hasMatch(values[2]) ||
      DateTime.tryParse(values[3])?.isUtc != true) {
    throw StateError('cloud_sync_write_observer_invalid');
  }
  return CloudKitWritePreparation(
    candidateFound: true,
    guidHash: values[2],
    createdAtUtc: values[3],
  );
}

Future<CloudKitWriteResult> invokeExactIntentAndWait({
  required VmService service,
  required String isolateId,
  required String libraryId,
  required String targetId,
  required String recipient,
  required String expectedGuidHash,
  Duration timeout = const Duration(seconds: 300),
}) async {
  if (!_guidHashPattern.hasMatch(expectedGuidHash)) {
    throw ArgumentError('write_guid_hash_invalid');
  }
  final recipientLiteral = jsonEncode(recipient);
  final hashLiteral = jsonEncode(expectedGuidHash);
  final observer = await service.evaluate(
    isolateId,
    libraryId,
    '''
    (() {
      final observation = <String>['pending', '', '', '', '', '', '', ''];
      Future<void> run() async {
        try {
          final selected = await writeTarget.selectCloudSyncV2ExactIntent(
            expectedRecipient: $recipientLiteral,
          );
          if (selected == null || selected.guidHash != $hashLiteral) {
            throw StateError('cloud_sync_outbound_candidate_changed');
          }
          final result = await writeTarget
              .runCloudSyncV2ExactIntentConfirmed(selected);
          observation[2] = selected.guidHash;
          observation[3] = result.admitted.toString();
          observation[4] = result.deferred.toString();
          observation[5] = result.outboxBlocked.toString();
          observation[6] = result.chatReadbackPending.toString();
          observation[7] = result.candidateLimitReached.toString();
          observation[0] = 'completed';
        } catch (error) {
          observation[0] = 'failed';
          final candidate = error is StateError ? error.message.toString() : '';
          observation[1] = RegExp(r'^cloud_sync_[a-z0-9_]+\$').hasMatch(candidate)
              ? candidate : 'cloud_sync_write_operation_failed';
        }
      }
      Future<void>(run);
      return observation;
    })()
  ''',
    scope: {'writeTarget': targetId},
    disableBreakpoints: true,
  );
  if (observer is! InstanceRef) {
    throw StateError('cloud_sync_write_observer_unavailable');
  }
  final values = await _waitForObservation(
    service: service,
    isolateId: isolateId,
    observer: observer,
    expectedLength: 8,
    terminalStates: const {'completed', 'failed'},
    timeout: timeout,
  );
  if (values[0] == 'failed') throw StateError(values[1]);
  final admitted = int.tryParse(values[3]);
  final deferred = int.tryParse(values[4]);
  if (values[2] != expectedGuidHash ||
      admitted == null ||
      admitted < 0 ||
      deferred == null ||
      deferred < 0 ||
      !const {'true', 'false'}.contains(values[5]) ||
      !const {'true', 'false'}.contains(values[6]) ||
      !const {'true', 'false'}.contains(values[7])) {
    throw StateError('cloud_sync_write_observer_invalid');
  }
  return CloudKitWriteResult(
    guidHash: values[2],
    admitted: admitted,
    deferred: deferred,
    outboxBlocked: values[5] == 'true',
    chatReadbackPending: values[6] == 'true',
    candidateLimitReached: values[7] == 'true',
  );
}

Future<
  ({VmService service, String isolateId, String libraryId, String targetId})
>
findWriteTarget(String uri) async {
  final service = await vmServiceConnectUri(uri);
  try {
    final vm = await service.getVM();
    for (final isolateRef in vm.isolates ?? const <IsolateRef>[]) {
      final isolateId = isolateRef.id;
      if (isolateId == null) continue;
      final isolate = await service.getIsolate(isolateId);
      for (final library in isolate.libraries ?? const <LibraryRef>[]) {
        if (!(library.uri ?? '').endsWith('/rustpush_service.dart')) continue;
        final libraryId = library.id;
        if (libraryId == null) continue;
        final object = await service.getObject(isolateId, libraryId);
        if (object is! Library) continue;
        final variable = (object.variables ?? const <FieldRef>[])
            .where((field) => field.name == 'pushService')
            .firstOrNull;
        if (variable?.id == null) continue;
        final field = await service.getObject(isolateId, variable!.id!);
        if (field is! Field || field.staticValue is! InstanceRef) continue;
        final target = field.staticValue as InstanceRef;
        if (target.id == null) continue;
        return (
          service: service,
          isolateId: isolateId,
          libraryId: libraryId,
          targetId: target.id!,
        );
      }
    }
    throw StateError('cloud_sync_write_ready_ui_isolate_not_found');
  } catch (_) {
    await service.dispose();
    rethrow;
  }
}

Future<void> main(List<String> args) async {
  if (args.length < 4 ||
      args.length > 5 ||
      !const {'--prepare', '--run', '--verify'}.contains(args[1]) ||
      (args[1] == '--prepare' && args.length != 4) ||
      (args[1] != '--prepare' && args.length != 5) ||
      args[2] != '--expect-recipient-sha256') {
    throw ArgumentError(
      'usage: vm_trigger_cloudkit_write.dart <ws-uri> '
      '<--prepare|--run|--verify> --expect-recipient-sha256 <sha256> '
      '[expected-guid-hash]',
    );
  }
  final recipient = Platform.environment[_recipientEnvironment] ?? '';
  final recipientHash = normalizedRecipientSha256(recipient);
  final expectedRecipientHash = args[3];
  if (!_sha256Pattern.hasMatch(expectedRecipientHash) ||
      recipientHash != expectedRecipientHash) {
    throw StateError('cloud_sync_write_recipient_hash_mismatch');
  }
  final expectedGuidHash = args[1] == '--prepare' ? null : args[4];
  final target = await findWriteTarget(args.first);
  try {
    if (args[1] == '--prepare') {
      final result = await invokePrepareAndSelect(
        service: target.service,
        isolateId: target.isolateId,
        libraryId: target.libraryId,
        targetId: target.targetId,
        recipient: recipient,
      );
      print(jsonEncode({...result.toJson(), 'recipientSha256': recipientHash}));
      if (!result.candidateFound) exitCode = 2;
      return;
    }
    final result = await invokeExactIntentAndWait(
      service: target.service,
      isolateId: target.isolateId,
      libraryId: target.libraryId,
      targetId: target.targetId,
      recipient: recipient,
      expectedGuidHash: expectedGuidHash!,
    );
    final verification = args[1] == '--verify';
    if (verification &&
        (result.admitted != 0 ||
            result.deferred != 0 ||
            result.outboxBlocked ||
            result.chatReadbackPending)) {
      throw StateError('cloud_sync_write_replay_not_settled');
    }
    print(
      jsonEncode({
        ...result.toJson(verification: verification),
        'recipientSha256': recipientHash,
      }),
    );
  } finally {
    await target.service.dispose();
  }
}
