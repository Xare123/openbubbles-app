import 'dart:convert';
import 'dart:typed_data';

String backendFixtureMarker(String id, {bool edited = false}) =>
    'OB-LAB-$id-v${edited ? 2 : 1}';

/// Shared by the app and private host manifest. Contains no personal content,
/// external downloads or user-selected paths.
Uint8List backendFixtureBytes(String id, String kind) => switch (kind) {
  'image' => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGOQqbnzH4QZYAwAUiwJzSNV9csAAAAASUVORK5CYII=',
  ),
  'document' => Uint8List.fromList(
    utf8.encode(
      '${backendFixtureMarker(id)}\nOpenBubbles backend document fixture.\n',
    ),
  ),
  _ => throw const FormatException('backend_invalid_fixture_kind'),
};
