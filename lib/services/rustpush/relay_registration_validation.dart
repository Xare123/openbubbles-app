enum RelayVersionResponseKind { success, rejected, failed, malformed }

class RelayVersionResponseValidation {
  const RelayVersionResponseValidation({
    required this.kind,
    required this.statusCode,
    this.versions,
  });

  final RelayVersionResponseKind kind;
  final int? statusCode;
  final Map<String, dynamic>? versions;
}

bool isCompleteOpenAbsintheCode(String value) {
  return RegExp(r'^[^-]{6}(?:-[^-]{4}){3}$').hasMatch(value);
}

bool isCompleteRelayCode(String value) {
  return RegExp(r'^[^-]{4}(?:-[^-]{4}){3}$').hasMatch(value);
}

bool isPotentialEncodedHardwareTransfer(String value) {
  if (value.length < 8 || value.length % 4 != 0) return false;
  return RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(value);
}

bool isRelayAppCredentialMissing(String appCredential) {
  return appCredential.trim().isEmpty;
}

bool isOfficialRelayHost({
  required String relayHost,
  required String officialRelayHost,
}) {
  final actual = _normalizeRelayOrigin(relayHost);
  final official = _normalizeRelayOrigin(officialRelayHost);
  if (actual == null || official == null) return false;
  return actual.scheme.toLowerCase() == official.scheme.toLowerCase() &&
      actual.host.toLowerCase() == official.host.toLowerCase() &&
      _effectiveRelayPort(actual) == _effectiveRelayPort(official);
}

Uri? _normalizeRelayOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
  if (uri.scheme.toLowerCase() != 'https') return null;
  if (uri.userInfo.isNotEmpty) return null;
  if (uri.host.isEmpty) return null;
  if ((uri.path.isNotEmpty && uri.path != '/') ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return null;
  }
  return uri;
}

int _effectiveRelayPort(Uri uri) => uri.hasPort ? uri.port : 443;

bool shouldBlockRelayRegistrationForMissingAppCredential({
  required String relayHost,
  required String appCredential,
  required String officialRelayHost,
}) {
  return isOfficialRelayHost(
        relayHost: relayHost,
        officialRelayHost: officialRelayHost,
      ) &&
      isRelayAppCredentialMissing(appCredential);
}

const String missingRelayAppCredentialMessage =
    'This build has no access to the registration relay. '
    'No request was sent and your device code was not checked. '
    'Use a relay-enabled build or contact its provider.';

const String relayAuthorizationFailedMessage =
    'The relay could not authorize this request. '
    'The device code or the app\u2019s relay access may need renewal. '
    'Check the relay setup or contact the build provider.';

RelayVersionResponseValidation validateRelayVersionResponse({
  required int? statusCode,
  required Object? data,
}) {
  if (statusCode == 401 || statusCode == 403) {
    return RelayVersionResponseValidation(
      kind: RelayVersionResponseKind.rejected,
      statusCode: statusCode,
    );
  }
  if (statusCode == null || statusCode < 200 || statusCode >= 300) {
    return RelayVersionResponseValidation(
      kind: RelayVersionResponseKind.failed,
      statusCode: statusCode,
    );
  }
  if (data is! Map || data['versions'] is! Map) {
    return RelayVersionResponseValidation(
      kind: RelayVersionResponseKind.malformed,
      statusCode: statusCode,
    );
  }

  late final Map<String, dynamic> versions;
  try {
    versions = Map<String, dynamic>.from(data['versions'] as Map);
  } catch (_) {
    return RelayVersionResponseValidation(
      kind: RelayVersionResponseKind.malformed,
      statusCode: statusCode,
    );
  }
  if (versions['software_name'] is! String ||
      versions['software_version'] is! String ||
      versions['unique_device_id'] is! String) {
    return RelayVersionResponseValidation(
      kind: RelayVersionResponseKind.malformed,
      statusCode: statusCode,
    );
  }
  return RelayVersionResponseValidation(
    kind: RelayVersionResponseKind.success,
    statusCode: statusCode,
    versions: versions,
  );
}
