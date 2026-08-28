package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeReliabilityScenarioTest {
    @Test
    fun incomingAnswerSurvivesNativeTimeoutUntilWebJoinIsConfirmed() {
        val callUuid = "incoming-fixture"
        val policy = FaceTimeJoinPolicy(manualRecoveryAttempt = 3, maxAttempts = 5)

        assertFalse(
            shouldFinishFaceTimeActivity(
                state = "timeout",
                isCall = true,
                answered = true,
                activityCallUuid = callUuid,
                requestedCallUuid = callUuid,
            ),
        )
        assertTrue(policy.record("\"clicked\"").retry)
        assertTrue(policy.record("\"hidden\"").retry)
        assertTrue(
            policy.record(
                "{\"outcome\":\"already-joined\",\"leaveVisible\":true,\"remoteParticipantCount\":1}",
            ).joined,
        )
    }

    @Test
    fun outgoingJoinRetriesThroughDelayedApplePageState() {
        val policy = FaceTimeJoinPolicy(manualRecoveryAttempt = 3, maxAttempts = 6)

        assertTrue(policy.record("\"missing\"").retry)
        assertTrue(policy.record("\"disabled\"").retry)
        assertTrue(policy.record("\"clicked\"").retry)
        assertTrue(
            policy.record(
                "{\"outcome\":\"already-joined\",\"leaveVisible\":true,\"remoteParticipantCount\":1}",
            ).joined,
        )
        assertFalse(policy.record("\"already-joined\"").retry)
    }

    @Test
    fun staleTimeoutCannotCloseAnotherCall() {
        assertFalse(
            shouldFinishFaceTimeActivity(
                state = "timeout",
                isCall = true,
                answered = false,
                activityCallUuid = "current-call",
                requestedCallUuid = "old-call",
            ),
        )
    }
}
