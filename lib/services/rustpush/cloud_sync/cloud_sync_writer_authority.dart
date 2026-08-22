// ignore_for_file: prefer_initializing_formals

import 'package:objectbox/objectbox.dart';

import 'cloud_sync_models.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// One revocable authorization to mutate a specific CloudKit account.
abstract interface class CloudSyncWriterPermit {
  Future<void> verify();
}

/// Required by every V2 engine configured with remote saves enabled.
abstract interface class CloudSyncWriterAuthority {
  Future<CloudSyncWriterPermit> issue(CloudSyncScope scope);
}

/// Production adapter from the platform-neutral engine to durable ObjectBox
/// writer ownership. A build not explicitly compiled as the V2 writer cannot
/// issue a permit.
final class ObjectBoxCloudSyncWriterAuthority
    implements CloudSyncWriterAuthority {
  ObjectBoxCloudSyncWriterAuthority({required Store store})
    : _authority = ObjectBoxCloudKitWriterAuthority(store: store);

  final ObjectBoxCloudKitWriterAuthority _authority;

  @override
  Future<CloudSyncWriterPermit> issue(CloudSyncScope scope) async {
    try {
      final writerScope = CloudKitWriterScope(
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
      );
      final permit = _authority.issuePermit(
        writerScope,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      return _ObjectBoxCloudSyncWriterPermit(
        authority: _authority,
        permit: permit,
      );
    } on CloudKitWriterAuthorityFailure catch (error) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: error.safeCode,
      );
    }
  }
}

final class _ObjectBoxCloudSyncWriterPermit implements CloudSyncWriterPermit {
  const _ObjectBoxCloudSyncWriterPermit({
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterPermit permit,
  }) : _authority = authority,
       _permit = permit;

  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitWriterPermit _permit;

  @override
  Future<void> verify() async {
    try {
      _authority.verifyPermit(_permit);
    } on CloudKitWriterAuthorityFailure catch (error) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: error.safeCode,
      );
    }
  }

  @override
  String toString() => 'CloudSyncWriterPermit(redacted)';
}
