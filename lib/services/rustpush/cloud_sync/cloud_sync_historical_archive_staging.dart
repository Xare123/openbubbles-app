import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_transport.dart';

/// Local encrypted-source handoff, not CloudKit admission or IDS delivery.
///
/// The caller owns snapshot qualification and must retain its engine until this
/// future finishes. The native callback validates and protects the exact source;
/// metadata alone never authenticates an imported snapshot. Production native
/// callback/producer wiring is separate from this local lifecycle.
final class CloudSyncHistoricalArchiveStaging {
  const CloudSyncHistoricalArchiveStaging({
    required this.journal,
    required this.transport,
    required this.capturedIdentity,
    required this.validateCurrentIdentity,
    required this.stillCurrent,
  });

  final CloudSyncHistoricalArchiveJournal journal;
  final CloudProtectedPageLeaseTransport transport;
  final CloudSyncNativeAuthSnapshot capturedIdentity;
  final Future<void> Function() validateCurrentIdentity;
  final bool Function() stillCurrent;

  Future<void> _validate() async {
    if (!stillCurrent()) {
      throw StateError('cloud_sync_historical_archive_identity_changed');
    }
    await validateCurrentIdentity();
    if (!stillCurrent()) {
      throw StateError('cloud_sync_historical_archive_identity_changed');
    }
  }

  /// Resume the retained descriptor first, including after a lost native commit
  /// response. Stage once only when there is no durable ownership for this exact
  /// snapshot/GUID/source. The cursor may advance only after this future succeeds.
  Future<CloudSyncHistoricalArchiveIntent> adopt({
    required String messageGuidHash,
    required String sourceSha256,
    required Future<CloudSyncHistoricalProtectedSourceBinding> Function()
    stageNative,
    void Function(CloudSyncHistoricalProtectedSourceBinding source)?
    validateSource,
  }) {
    if (journal.accountFingerprint != capturedIdentity.accountFingerprint ||
        journal.protectedStoreIdentity !=
            capturedIdentity.protectedStoreIdentity ||
        transport.protectedPageLeaseRecoveryIdentity !=
            journal.protectedStoreIdentity) {
      throw StateError('cloud_sync_historical_archive_identity_changed');
    }
    final local = transport;
    if (local is! CloudProtectedLocalLifecycleTransport) {
      throw StateError(
        'cloud_sync_historical_archive_store_exclusion_unavailable',
      );
    }
    // Reuse native cross-engine store exclusion, not an isolate-only mutex and
    // not the network writer lock. GC/recovery cannot race source adoption.
    return (local as CloudProtectedLocalLifecycleTransport)
        .runLocalProtectedStoreExclusive(() async {
          await _validate();
          final existing = journal.read(
            messageGuidHash: messageGuidHash,
            sourceSha256: sourceSha256,
          );
          final source = existing?.source ?? await stageNative();
          // A foreign or mismatched descriptor is not authority to roll back its
          // lease. Only an exact fresh source from our trusted callback is ours.
          source.requireOrigin(
            accountFingerprint: journal.accountFingerprint,
            protectedStoreIdentity: journal.protectedStoreIdentity,
            snapshotSha256: journal.snapshotSha256,
            messageGuidHash: messageGuidHash,
            sourceSha256: sourceSha256,
          );
          // Validate exact canonical payload expectations for both newly staged
          // and retained sources before either journal adoption or native commit.
          validateSource?.call(source);
          var adoptionAttempted = existing != null;
          try {
            await _validate();
            // Conservatively retain after any attempted durable adoption. Even an
            // ambiguous storage error is not permission to destroy a source.
            adoptionAttempted = true;
            final adopted = existing ?? journal.adopt(source);
            await transport.commitProtectedPageLease(source.leaseReference, {
              source.protectedReference,
            });
            await _validate();
            final retained = journal.read(
              messageGuidHash: messageGuidHash,
              sourceSha256: sourceSha256,
            );
            if (retained == null ||
                retained.id != adopted.id ||
                retained.source.encode() != source.encode()) {
              throw StateError('cloud_sync_historical_journal_source_conflict');
            }
            return journal.markSourceLeaseCommitted(
              intentId: adopted.id,
              expectedSource: source,
            );
          } catch (_) {
            if (!adoptionAttempted) {
              try {
                await transport.rollbackProtectedPageLease(
                  source.leaseReference,
                );
              } catch (_) {
                // Existing orphan recovery handles an unadopted source. Preserve
                // the primary failure and never report successful adoption here.
              }
            }
            rethrow;
          }
        });
  }
}
