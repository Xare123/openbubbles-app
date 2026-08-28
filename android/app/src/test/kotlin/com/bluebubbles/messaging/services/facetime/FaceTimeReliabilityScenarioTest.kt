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
        policy.recordMediaEvidence(remoteMedia(100))
        assertTrue(policy.recordMediaEvidence(remoteMedia(180)).joined)
    }

    @Test
    fun outgoingJoinRetriesThroughDelayedApplePageState() {
        val policy = FaceTimeJoinPolicy(manualRecoveryAttempt = 3, maxAttempts = 6)

        assertTrue(policy.record("\"missing\"").retry)
        assertTrue(policy.record("\"disabled\"").retry)
        assertTrue(policy.record("\"clicked\"").retry)
        policy.recordMediaEvidence(remoteMedia(100))
        assertTrue(policy.recordMediaEvidence(remoteMedia(180)).joined)
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

    private fun remoteMedia(bytes: Long) = FaceTimeMediaEvidence(
        iceState = FaceTimeIceState.CONNECTED,
        remoteAudioTracks = 1,
        remoteVideoTracks = 0,
        mediaBytes = bytes,
        webLeaveVisible = true,
        peerId = 1,
    )
}
