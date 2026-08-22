package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeMediaAdmissionReplayTest {
    @Test
    fun replaysPendingToConnectedMediaAdmissionAndMediaLoss() {
        val policy = FaceTimeJoinPolicy()

        val checking = policy.recordMediaEvidence(
            evidence(
                iceState = FaceTimeIceState.CHECKING,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = null,
                peerId = null,
            ),
        )
        assertFalse(checking.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_PENDING, checking.outcome)

        val failed = policy.recordMediaEvidence(
            evidence(
                iceState = FaceTimeIceState.FAILED,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = null,
                peerId = null,
            ),
        )
        assertFalse(failed.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_FAILED, failed.outcome)

        val connectedWithoutTrack = policy.recordMediaEvidence(
            evidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = 0,
                peerId = 7,
            ),
        )
        assertFalse(connectedWithoutTrack.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_PENDING, connectedWithoutTrack.outcome)

        val zeroInboundBytes = policy.recordMediaEvidence(
            evidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 0,
                peerId = 7,
            ),
        )
        assertFalse(zeroInboundBytes.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_PENDING, zeroInboundBytes.outcome)

        val firstInboundSample = policy.recordMediaEvidence(
            evidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 128,
                peerId = 7,
            ),
        )
        assertFalse(firstInboundSample.joined)

        val admitted = policy.recordMediaEvidence(
            evidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 256,
                peerId = 7,
            ),
        )
        assertTrue(admitted.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_CONNECTED, admitted.outcome)

        val mediaLoss = policy.recordMediaEvidence(
            evidence(
                iceState = FaceTimeIceState.DISCONNECTED,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = null,
                peerId = null,
            ),
        )
        assertFalse(mediaLoss.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_PENDING, mediaLoss.outcome)
        assertTrue(policy.completedJoin)
        assertFalse(mediaLoss.retry)
    }

    @Test
    fun connectedVideoOnlyCallAdmitsVideoWithoutAudio() {
        val policy = FaceTimeJoinPolicy()
        policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 0,
                remoteVideoTracks = 1,
                mediaBytes = 64,
                webLeaveVisible = true,
                peerId = 1,
            ),
        )
        val decision = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 0,
                remoteVideoTracks = 1,
                mediaBytes = 128,
                webLeaveVisible = true,
                peerId = 1,
            ),
        )

        assertTrue(decision.joined)
    }

    @Test
    fun zeroInboundBytesMustNotAdmitEvenWhenRemoteTracksExist() {
        val decision = FaceTimeJoinPolicy().recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 0,
                webLeaveVisible = true,
                peerId = 1,
            ),
        )

        assertFalse("a connected track with no inbound bytes is not verified media", decision.joined)
    }

    @Test
    fun inboundBytesMustIncreaseBeforeMediaIsAdmitted() {
        val policy = FaceTimeJoinPolicy()

        val firstSample = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 128,
                webLeaveVisible = true,
                peerId = 1,
            ),
        )
        val secondSample = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 256,
                webLeaveVisible = true,
                peerId = 1,
            ),
        )

        assertFalse("one positive counter sample does not prove media is flowing", firstSample.joined)
        assertTrue("a later larger counter sample proves inbound progress", secondSample.joined)
    }

    @Test
    fun peerReplacementRequiresASecondSampleFromTheNewPeer() {
        val policy = FaceTimeJoinPolicy()
        policy.recordMediaEvidence(connectedEvidence(peerId = 1, mediaBytes = 100))
        val replacement = policy.recordMediaEvidence(connectedEvidence(peerId = 2, mediaBytes = 200))
        val confirmed = policy.recordMediaEvidence(connectedEvidence(peerId = 2, mediaBytes = 250))

        assertFalse(replacement.joined)
        assertTrue(confirmed.joined)
    }

    @Test
    fun counterResetRequiresTwoFreshPostResetSamples() {
        val policy = FaceTimeJoinPolicy()
        policy.recordMediaEvidence(connectedEvidence(peerId = 1, mediaBytes = 100))
        val reset = policy.recordMediaEvidence(connectedEvidence(peerId = 1, mediaBytes = 0))
        val firstAfterReset = policy.recordMediaEvidence(connectedEvidence(peerId = 1, mediaBytes = 1))
        val advancingAfterReset = policy.recordMediaEvidence(connectedEvidence(peerId = 1, mediaBytes = 2))

        assertFalse(reset.joined)
        assertFalse(firstAfterReset.joined)
        assertTrue(advancingAfterReset.joined)
    }

    @Test
    fun missingPeerIdentityCannotAdmitMedia() {
        val policy = FaceTimeJoinPolicy()
        policy.recordMediaEvidence(connectedEvidence(peerId = null, mediaBytes = 100))
        val decision = policy.recordMediaEvidence(connectedEvidence(peerId = null, mediaBytes = 200))

        assertFalse(decision.joined)
    }

    private fun connectedEvidence(peerId: Int?, mediaBytes: Long) = FaceTimeMediaEvidence(
        iceState = FaceTimeIceState.CONNECTED,
        remoteAudioTracks = 1,
        remoteVideoTracks = 1,
        mediaBytes = mediaBytes,
        webLeaveVisible = true,
        peerId = peerId,
    )

    private fun evidence(
        iceState: FaceTimeIceState,
        remoteAudioTracks: Int,
        remoteVideoTracks: Int,
        mediaBytes: Long?,
        peerId: Int?,
    ) = FaceTimeMediaEvidence(
        iceState = iceState,
        remoteAudioTracks = remoteAudioTracks,
        remoteVideoTracks = remoteVideoTracks,
        mediaBytes = mediaBytes,
        webLeaveVisible = true,
        peerId = peerId,
    )
}
