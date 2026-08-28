package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeJoinPolicyTest {
    @Test
    fun clickedKeepsRetryingUntilJoinedStateIsObserved() {
        val decision = FaceTimeJoinPolicy().record("\"clicked\"")

        assertEquals(FaceTimeJoinOutcome.CLICKED, decision.outcome)
        assertFalse(decision.joined)
        assertFalse(decision.revealManualRecovery)
        assertTrue(decision.retry)
    }

    @Test
    fun leaveWithoutRemoteEvidenceStaysConnecting() {
        val decision = FaceTimeJoinPolicy().record(
            "{\"outcome\":\"already-joined\",\"leaveVisible\":true,\"remoteParticipantCount\":0}"
        )

        assertFalse(decision.joined)
        assertTrue(decision.retry)
    }

    @Test
    fun remoteParticipantEvidenceCompletesJoin() {
        val decision = FaceTimeJoinPolicy().record(
            "{\"outcome\":\"already-joined\",\"leaveVisible\":true,\"remoteParticipantCount\":1}"
        )

        assertTrue(decision.joined)
        assertFalse(decision.retry)
    }

    @Test
    fun selfPreviewDoesNotCompleteJoin() {
        val decision = FaceTimeJoinPolicy().recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = 256,
                webLeaveVisible = true,
                peerId = 1,
                remoteParticipantCount = 0,
            ),
        )

        assertFalse(decision.joined)
    }

    @Test
    fun manualRecoveryAppearsWhileRetriesContinue() {
        val policy = FaceTimeJoinPolicy(manualRecoveryAttempt = 2, maxAttempts = 4)

        val first = policy.record("\"missing\"")
        val second = policy.record("\"hidden\"")

        assertFalse(first.revealManualRecovery)
        assertTrue(first.retry)
        assertTrue(second.revealManualRecovery)
        assertTrue(second.retry)
    }

    @Test
    fun retriesEventuallyStop() {
        val policy = FaceTimeJoinPolicy(manualRecoveryAttempt = 1, maxAttempts = 2)

        policy.record("\"disabled\"")
        val finalDecision = policy.record(null)

        assertEquals(FaceTimeJoinOutcome.UNKNOWN, finalDecision.outcome)
        assertTrue(finalDecision.revealManualRecovery)
        assertFalse(finalDecision.retry)
    }

    @Test
    fun remoteMediaRequiresAdvancingInboundBytes() {
        val policy = FaceTimeJoinPolicy()
        val first = policy.recordMediaEvidence(remoteMedia(128))
        val second = policy.recordMediaEvidence(remoteMedia(256))

        assertFalse(first.joined)
        assertTrue(second.joined)
    }

    private fun remoteMedia(bytes: Long) = FaceTimeMediaEvidence(
        iceState = FaceTimeIceState.CONNECTED,
        remoteAudioTracks = 1,
        remoteVideoTracks = 0,
        mediaBytes = bytes,
        webLeaveVisible = true,
        peerId = 1,
        remoteParticipantCount = 0,
    )
}
