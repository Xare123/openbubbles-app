import 'dart:convert';

const extensionTestBundle = 'com.example.synthetic';

String extensionTestJson({String name = 'Synthetic App', String bundleId = extensionTestBundle}) => jsonEncode({
  'version': 1,
  'metadata': {
    'name': name,
    'app_id': 1234,
    'bundle_id': bundleId,
    'balloon': {
      'url': 'app:synthetic',
      'session': '01010101-0101-0101-0101-010101010101',
      'ld_text': 'Synthetic description',
      'is_live': true,
      'icon': [0, 1, 127, 128, 255],
      'layout': {
        'image_subtitle': 'is',
        'image_title': 'it',
        'caption': 'c',
        'secondary_subcaption': 'ss',
        'tertiary_subcaption': 'ts',
        'subcaption': 's',
      },
    },
  },
});

/// Bounded v2 wire envelope: same exact v1 metadata keys plus a closed
/// session-binding context. Base GUID equals the parent wire identity; each
/// update GUID is its own opaque value pointing at the 43-char URL-safe base
/// logical-key hash. Caller supplies 43-char URL-safe hashes only.
Map<String, dynamic> extensionTestV2Map({
  String role = 'base',
  required String sessionGuid,
  required String sessionLogicalKeyHash,
  String name = 'Synthetic App',
  String bundleId = extensionTestBundle,
}) => {
  'version': 2,
  'metadata': {
    'name': name,
    'app_id': 1234,
    'bundle_id': bundleId,
    'balloon': {
      'url': 'app:synthetic',
      'session': '01010101-0101-0101-0101-010101010101',
      'ld_text': 'Synthetic description',
      'is_live': true,
      'icon': [0, 1, 127, 128, 255],
      'layout': {
        'image_subtitle': 'is',
        'image_title': 'it',
        'caption': 'c',
        'secondary_subcaption': 'ss',
        'tertiary_subcaption': 'ts',
        'subcaption': 's',
      },
    },
  },
  'context': {
    'role': role,
    'session_guid': sessionGuid,
    'session_logical_key_hash': sessionLogicalKeyHash,
  },
};

String extensionTestV2Json({
  String role = 'base',
  required String sessionGuid,
  required String sessionLogicalKeyHash,
  String name = 'Synthetic App',
  String bundleId = extensionTestBundle,
}) => jsonEncode(
  extensionTestV2Map(
    role: role,
    sessionGuid: sessionGuid,
    sessionLogicalKeyHash: sessionLogicalKeyHash,
    name: name,
    bundleId: bundleId,
  ),
);
