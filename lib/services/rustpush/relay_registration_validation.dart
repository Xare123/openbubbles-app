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

  final versions = Map<String, dynamic>.from(data['versions'] as Map);
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
