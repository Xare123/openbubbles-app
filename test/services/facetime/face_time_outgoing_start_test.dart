import 'dart:io';

import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('IDS 6005 produces a registration repair notice', () {
    expect(
      faceTimeOutgoingStartFailureMessage(
        Exception('Registration Error Bad authentication. (6005)'),
      ),
      'Your iMessage registration needs repair. No FaceTime call was placed.',
    );
  });

  test('other start failures never claim a call was placed', () {
    expect(
      faceTimeOutgoingStartFailureMessage(Exception('network unavailable')),
      'FaceTime could not start. No call was placed.',
    );
  });

  test('ringing overlay is admitted only after session creation succeeds', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> placeOutgoingCall(');
    final end = source.indexOf('\n  // returns handle to show poster of', start);
    final method = source.substring(start, end);

    expect(method.indexOf('await api.createFacetime('), greaterThan(-1));
    expect(method.indexOf('showOutgoingFaceTimeOverlay('), greaterThan(-1));
    expect(
      method.indexOf('await api.createFacetime('),
      lessThan(method.indexOf('showOutgoingFaceTimeOverlay(')),
    );
    expect(method, contains('currentOutgoingCall = null;'));
    expect(method, contains('faceTimeOutgoingStartFailureMessage(error)'));
  });
}
