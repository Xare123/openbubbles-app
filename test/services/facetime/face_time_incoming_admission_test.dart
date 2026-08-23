import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final receivedAt = DateTime.utc(2026, 8, 21, 12);

  FaceTimeIncomingAdmissionCorrelation pendingCall() =>
      FaceTimeIncomingAdmissionCorrelation(
        callUuid: 'incoming-call-uuid',
        receivedAt: receivedAt,
      );

  test('answers only an explicitly approved incoming admission', () {
    expect(
      shouldAnswerIncomingFaceTimeAdmission(
        const FaceTimeIncomingAdmissionResult.approved('incoming-call-uuid'),
      ),
      isTrue,
    );
    expect(shouldAnswerIncomingFaceTimeAdmission(null), isFalse);

    for (final status in FaceTimeIncomingAdmissionStatus.values.where(
      (status) => status != FaceTimeIncomingAdmissionStatus.approved,
    )) {
      expect(
        shouldAnswerIncomingFaceTimeAdmission(
          FaceTimeIncomingAdmissionResult.rejected(status),
        ),
        isFalse,
        reason: 'rejected admission $status must not send an answer',
      );
    }
  });

  test(
    'rejected and missing incoming admissions never invoke the answer',
    () async {
      var answerCount = 0;

      Future<void> answer(String? approvedGroup) async {
        answerCount += 1;
      }

      expect(
        await answerFaceTimeAdmissionIfAllowed(
          isIncomingAdmission: true,
          incomingAdmission: null,
          correlation: null,
          fallbackApprovedGroup: 'must-not-be-used',
          answer: answer,
        ),
        isFalse,
      );
      for (final status in FaceTimeIncomingAdmissionStatus.values.where(
        (status) => status != FaceTimeIncomingAdmissionStatus.approved,
      )) {
        expect(
          await answerFaceTimeAdmissionIfAllowed(
            isIncomingAdmission: true,
            incomingAdmission: FaceTimeIncomingAdmissionResult.rejected(status),
            correlation: null,
            fallbackApprovedGroup: 'must-not-be-used',
            answer: answer,
          ),
          isFalse,
        );
      }

      expect(answerCount, 0);
    },
  );

  test(
    'approved incoming admission answers and completes its ticket',
    () async {
      final correlation = pendingCall();
      final admission = correlation.claim(
        activeCallUuid: 'incoming-call-uuid',
        now: receivedAt.add(const Duration(seconds: 10)),
      );
      String? answeredGroup;

      expect(
        await answerFaceTimeAdmissionIfAllowed(
          isIncomingAdmission: true,
          incomingAdmission: admission,
          correlation: correlation,
          fallbackApprovedGroup: 'must-not-be-used',
          answer: (approvedGroup) async => answeredGroup = approvedGroup,
        ),
        isTrue,
      );
      expect(answeredGroup, 'incoming-call-uuid');
      expect(correlation.isCompleted, isTrue);
    },
  );

  test('failed incoming answer releases the ticket for retry', () async {
    final correlation = pendingCall();
    final admission = correlation.claim(
      activeCallUuid: 'incoming-call-uuid',
      now: receivedAt.add(const Duration(seconds: 10)),
    );

    await expectLater(
      answerFaceTimeAdmissionIfAllowed(
        isIncomingAdmission: true,
        incomingAdmission: admission,
        correlation: correlation,
        fallbackApprovedGroup: null,
        answer: (_) async => throw StateError('expected test failure'),
      ),
      throwsStateError,
    );
    expect(
      correlation
          .claim(
            activeCallUuid: 'incoming-call-uuid',
            now: receivedAt.add(const Duration(seconds: 11)),
          )
          .isApproved,
      isTrue,
    );
  });

  test('non-incoming admission retains its fallback group behavior', () async {
    String? answeredGroup;

    expect(
      await answerFaceTimeAdmissionIfAllowed(
        isIncomingAdmission: false,
        incomingAdmission: null,
        correlation: null,
        fallbackApprovedGroup: 'chosen-room-guid',
        answer: (approvedGroup) async => answeredGroup = approvedGroup,
      ),
      isTrue,
    );
    expect(answeredGroup, 'chosen-room-guid');
  });

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
