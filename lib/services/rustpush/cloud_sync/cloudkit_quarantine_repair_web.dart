import 'cloud_inbox_applier.dart';
import 'cloud_sync_models.dart';

/// Web has no ObjectBox store or CloudKit V2 repair lane. This conditional
/// surface keeps the public types available without importing the native
/// ObjectBox implementation into a web compilation unit.
final class CloudKitV2ConverterCorrection {
  const CloudKitV2ConverterCorrection({
    required this.converterRevision,
    required this.correctionName,
  });

  static const messageFamilyAssociation = CloudKitV2ConverterCorrection(
    converterRevision: 'cloud-canonical-converter-r2',
    correctionName: 'message-family-outer-class-association',
  );

  final String converterRevision;
  final String correctionName;

  @override
  bool operator ==(Object other) =>
      other is CloudKitV2ConverterCorrection &&
      other.converterRevision == converterRevision &&
      other.correctionName == correctionName;

  @override
  int get hashCode => Object.hash(converterRevision, correctionName);
}

final class CloudKitV2QuarantineRepairAllowlist {
  const CloudKitV2QuarantineRepairAllowlist._();

  static const only = CloudKitV2ConverterCorrection.messageFamilyAssociation;

  static bool permits(CloudKitV2ConverterCorrection correction) =>
      correction == only;
}

final class CloudKitV2QuarantineRepairRequest {
  CloudKitV2QuarantineRepairRequest({
    required this.scope,
    required this.generation,
    required this.changeIdHash,
    required this.correction,
  }) {
    if (generation <= 0 || !_digestPattern.hasMatch(changeIdHash)) {
      throw ArgumentError('cloudkit_quarantine_repair_request_invalid');
    }
    if (!_revisionPattern.hasMatch(correction.converterRevision) ||
        !_safeCodePattern.hasMatch(correction.correctionName)) {
      throw ArgumentError('cloudkit_quarantine_repair_correction_invalid');
    }
  }

  static final _digestPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _revisionPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
  static final _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');

  final CloudSyncScope scope;
  final int generation;
  final String changeIdHash;
  final CloudKitV2ConverterCorrection correction;
}

enum CloudKitV2QuarantineRepairDisposition {
  disabled,
  retryable,
  repaired,
  alreadyRepaired,
  failed,
  alreadyFailed,
}

final class CloudKitV2QuarantineRepairResult {
  const CloudKitV2QuarantineRepairResult._({
    required this.disposition,
    required this.repairKey,
    this.failureCategory,
    this.safeCode,
  });

  const CloudKitV2QuarantineRepairResult.disabled(String repairKey)
    : this._(
        disposition: CloudKitV2QuarantineRepairDisposition.disabled,
        repairKey: repairKey,
      );

  const CloudKitV2QuarantineRepairResult.retryable(
    String repairKey, {
    required CloudFailureCategory failureCategory,
    required String safeCode,
  }) : this._(
         disposition: CloudKitV2QuarantineRepairDisposition.retryable,
         repairKey: repairKey,
         failureCategory: failureCategory,
         safeCode: safeCode,
       );

  final CloudKitV2QuarantineRepairDisposition disposition;
  final String repairKey;
  final CloudFailureCategory? failureCategory;
  final String? safeCode;

  bool get succeeded =>
      disposition == CloudKitV2QuarantineRepairDisposition.repaired ||
      disposition == CloudKitV2QuarantineRepairDisposition.alreadyRepaired;
}

/// Explicitly unavailable on web. The native ObjectBox implementation is not
/// represented here and no web persistence or remote write is attempted.
final class CloudKitV2QuarantineRepairGateway {
  const CloudKitV2QuarantineRepairGateway({
    Object? store,
    Object? canonicalAdapter,
    DateTime Function()? clock,
    this.enabled = false,
  });

  final bool enabled;

  Future<CloudKitV2QuarantineRepairResult> repair({
    required CloudKitV2QuarantineRepairRequest request,
    required CloudSemanticDecoder correctedDecoder,
  }) async =>
      const CloudKitV2QuarantineRepairResult.disabled('web-unavailable');
}
