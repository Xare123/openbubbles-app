import 'dart:io';

import 'package:bluebubbles/services/rustpush/face_time_outgoing_acceptance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const self = 'tel:+15550001111';
  const remote = 'tel:+15550002222';
  const guid = 'OUTGOING-GUID';

  FaceTimeOutgoingParticipant participant(String handle, bool active) =>
      FaceTimeOutgoingParticipant(handle: handle, active: active);

  test('self-echo join stays pending', () {
    expect(
      shouldAcceptOutgoingFaceTimeJoin(
        sessionGroupId: guid,
        eventGuid: guid,
        eventHandle: self,
        selfHandles: [self],
        participants: [participant(self, true)],
      ),
      isFalse,
    );
  });

  test('invited-but-inactive remote stays pending', () {
    expect(
      shouldAcceptOutgoingFaceTimeJoin(
        sessionGroupId: guid,
        eventGuid: guid,
        eventHandle: remote,
        selfHandles: [self],
        participants: [participant(remote, false)],
      ),
      isFalse,
    );
  });

  test('missing or stale session stays pending', () {
    expect(
      shouldAcceptOutgoingFaceTimeJoin(
        sessionGroupId: null,
        eventGuid: guid,
        eventHandle: remote,
        selfHandles: [self],
        participants: [participant(remote, true)],
      ),
      isFalse,
    );
    expect(
      shouldAcceptOutgoingFaceTimeJoin(
        sessionGroupId: 'STALE-GUID',
        eventGuid: guid,
        eventHandle: remote,
        selfHandles: [self],
        participants: [participant(remote, true)],
      ),
      isFalse,
    );
    expect(
      shouldAcceptOutgoingFaceTimeJoin(
        sessionGroupId: guid,
        eventGuid: guid,
        eventHandle: remote,
        selfHandles: const <String>[],
        participants: [participant(remote, true)],
      ),
      isFalse,
    );
  });

  test('joined remote accepts', () {
    expect(
      shouldAcceptOutgoingFaceTimeJoin(
        sessionGroupId: guid,
        eventGuid: guid,
        eventHandle: remote,
        selfHandles: [self],
        participants: [
          participant(self, true),
          participant(remote, true),
        ],
      ),
      isTrue,
    );
  });

  test('duplicate accept and different call stay disjoint', () {
    // Same joined remote repeated: gate still returns true each time, so
    // the single-claim async ownership (`complete`) dedupes; no state flip
    // is encoded here.
    for (var i = 0; i < 2; i++) {
      expect(
        shouldAcceptOutgoingFaceTimeJoin(
          sessionGroupId: guid,
          eventGuid: guid,
          eventHandle: remote,
          selfHandles: [self],
          participants: [participant(remote, true)],
        ),
        isTrue,
      );
    }
    expect(
      shouldAcceptOutgoingFaceTimeJoin(
        sessionGroupId: 'OTHER-GUID',
        eventGuid: guid,
        eventHandle: remote,
        selfHandles: [self],
        participants: [participant(remote, true)],
      ),
      isFalse,
    );
  });

  test('production acceptance uses the tested helper', () {
    final source =
        File('lib/services/rustpush/rustpush_service.dart').readAsStringSync();
    final start = source.indexOf('if (facetime is api.FTMessage_JoinEvent) {');
    final end = source.indexOf(
      '} else if (facetime is api.FTMessage_AddMembers) {',
      start,
    );
    final block = source.substring(start, end);
    expect(block, contains('shouldAcceptOutgoingFaceTimeJoin('));
    expect(
      block.indexOf('shouldAcceptOutgoingFaceTimeJoin('),
      lessThan(block.indexOf('outgoingCall.state.value = "accepted"')),
    );
    expect(block, contains('participant.active != null'));
    expect(block, contains('snapshot?.myHandles'));
  });
}
