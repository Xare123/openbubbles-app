import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device probe targets the Dart VM websocket endpoint', () {
    final source = File(
      'tooling/cloudkit_canary_device_probe.ps1',
    ).readAsStringSync();
    const websocketPath =
        r'''$uriBuilder.Path = "$($uriBuilder.Path.TrimEnd('/'))/ws"''';

    expect(source, contains(websocketPath));
    final websocketIndex = source.indexOf(websocketPath);
    final invokeIndex = source.indexOf(
      'Invoke-DartTrigger -Uri',
      websocketIndex,
    );
    expect(invokeIndex, greaterThan(websocketIndex));
  });
}
