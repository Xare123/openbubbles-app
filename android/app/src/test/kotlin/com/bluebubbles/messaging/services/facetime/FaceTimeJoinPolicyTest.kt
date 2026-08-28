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
            "{\"outcome\":\"already-joined\",\"leaveVisible\":true}"
        )

        assertFalse(decision.joined)
        assertTrue(decision.retry)
    }

    @Test
    fun domParticipantCountNeverCompletesJoin() {
        val decision = FaceTimeJoinPolicy().record(
            "{\"outcome\":\"already-joined\",\"leaveVisible\":true}"
        )

        assertFalse(decision.joined)
        assertTrue(decision.retry)
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

    @Test
    fun joinedStateStaysJoinedAfterIdleOrStatsFailure() {
        val policy = FaceTimeJoinPolicy()
        policy.recordMediaEvidence(remoteMedia(128))
        assertTrue(policy.recordMediaEvidence(remoteMedia(256)).joined)

        val idle = policy.recordMediaEvidence(remoteMedia(256))
        val unavailable = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.UNKNOWN,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = null,
                webLeaveVisible = false,
            ),
        )

        assertTrue(idle.joined)
        assertTrue(unavailable.joined)
    }

    @Test
    fun multiplePeersRequireAdvancingRemoteMediaOnOnePeer() {
        val policy = FaceTimeJoinPolicy()
        val first = FaceTimeMediaEvidence(
            iceState = FaceTimeIceState.CONNECTED,
            remoteAudioTracks = 0,
            remoteVideoTracks = 0,
            mediaBytes = null,
            webLeaveVisible = true,
            peers = listOf(remotePeer(1, 100), remotePeer(2, 400)),
        )
        val second = first.copy(peers = listOf(remotePeer(1, 100), remotePeer(2, 512)))

        assertFalse(policy.recordMediaEvidence(first).joined)
        assertTrue(policy.recordMediaEvidence(second).joined)
    }

    @Test
    fun peerReplacementStartsANewBaseline() {
        val policy = FaceTimeJoinPolicy()
        assertFalse(policy.recordMediaEvidence(withPeer(remotePeer(1, 100))).joined)
        assertFalse(policy.recordMediaEvidence(withPeer(remotePeer(2, 100))).joined)
        assertTrue(policy.recordMediaEvidence(withPeer(remotePeer(2, 180))).joined)
    }

    private fun remoteMedia(bytes: Long) = FaceTimeMediaEvidence(
        iceState = FaceTimeIceState.CONNECTED,
        remoteAudioTracks = 1,
        remoteVideoTracks = 0,
        mediaBytes = bytes,
        webLeaveVisible = true,
        peerId = 1,
    )

    private fun remotePeer(id: Int, bytes: Long) = FaceTimePeerMediaEvidence(
        peerId = id,
        iceState = FaceTimeIceState.CONNECTED,
        remoteAudioTracks = 1,
        remoteVideoTracks = 0,
        mediaBytes = bytes,
    )

    private fun withPeer(peer: FaceTimePeerMediaEvidence) = FaceTimeMediaEvidence(
        iceState = FaceTimeIceState.UNKNOWN,
        remoteAudioTracks = 0,
        remoteVideoTracks = 0,
        mediaBytes = null,
        webLeaveVisible = true,
        peers = listOf(peer),
    )
}
