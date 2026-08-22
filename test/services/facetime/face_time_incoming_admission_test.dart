import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final receivedAt = DateTime.utc(2026, 8, 21, 12);

  FaceTimeIncomingAdmissionCorrelation pendingCall() =>
      FaceTimeIncomingAdmissionCorrelation(
        callUuid: 'incoming-call-uuid',
        receivedAt: receivedAt,
      );

  test('approves a current request whose active call UUID matches', () {
    final admission = pendingCall();

    final result = admission.claim(
      activeCallUuid: 'incoming-call-uuid',
      now: receivedAt.add(const Duration(seconds: 10)),
    );

    expect(result.status, FaceTimeIncomingAdmissionStatus.approved);
    expect(result.approvedGroup, 'incoming-call-uuid');
    admission.complete();
    expect(
      admission
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(const Duration(seconds: 11)),
          )
          .status,
      FaceTimeIncomingAdmissionStatus.approved,
    );
    expect(
      admission
          .claim(
            activeCallUuid: 'different-call-uuid',
            now: receivedAt.add(const Duration(seconds: 12)),
          )
          .status,
      FaceTimeIncomingAdmissionStatus.mismatched,
    );
    expect(
      admission
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(
              FaceTimeIncomingAdmissionCorrelation.maxAge +
                  const Duration(seconds: 1),
            ),
          )
          .status,
      FaceTimeIncomingAdmissionStatus.stale,
    );
  });

  test('ignores a duplicate while the first admission is in flight', () {
    final admission = pendingCall();

    expect(
      admission
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(const Duration(seconds: 10)),
          )
          .status,
      FaceTimeIncomingAdmissionStatus.approved,
    );
    expect(
      admission
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(const Duration(seconds: 11)),
          )
          .status,
      FaceTimeIncomingAdmissionStatus.alreadyClaimed,
    );
  });

  test('releases a failed in-flight response so the same call can retry', () {
    final admission = pendingCall();

    expect(
      admission
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(const Duration(seconds: 10)),
          )
          .status,
      FaceTimeIncomingAdmissionStatus.approved,
    );
    admission.release();
    expect(
      admission
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(const Duration(seconds: 11)),
          )
          .status,
      FaceTimeIncomingAdmissionStatus.approved,
    );
  });

  test('does not consume the pending call when the active UUID is missing', () {
    final admission = pendingCall();

    final missing = admission.claim(
      activeCallUuid: null,
      now: receivedAt.add(const Duration(seconds: 10)),
    );

    expect(missing.status, FaceTimeIncomingAdmissionStatus.missingCallUuid);
    expect(
      admission
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(const Duration(seconds: 11)),
          )
          .approvedGroup,
      'incoming-call-uuid',
    );
  });

  test('rejects a request after the bounded pending-call lifetime', () {
    final admission = pendingCall();

    final result = admission.claim(
      activeCallUuid: 'incoming-call-uuid',
      now: receivedAt.add(
        FaceTimeIncomingAdmissionCorrelation.maxAge +
            const Duration(seconds: 1),
      ),
    );

    expect(result.status, FaceTimeIncomingAdmissionStatus.stale);
    expect(result.approvedGroup, isNull);
  });

  test('rejects a mismatched active UUID without approving another call', () {
    final admission = pendingCall();

    final mismatch = admission.claim(
      activeCallUuid: 'different-call-uuid',
      now: receivedAt.add(const Duration(seconds: 10)),
    );

    expect(mismatch.status, FaceTimeIncomingAdmissionStatus.mismatched);
    expect(mismatch.approvedGroup, isNull);
    expect(
      admission
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(const Duration(seconds: 11)),
          )
          .approvedGroup,
      'incoming-call-uuid',
    );
  });
}
