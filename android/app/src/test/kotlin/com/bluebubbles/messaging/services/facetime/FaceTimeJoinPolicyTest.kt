package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeJoinPolicyTest {
    @Test
    fun clickedRequestsAdmissionButDoesNotClaimJoined() {
        val decision = FaceTimeJoinPolicy().record("\"clicked\"")

        assertEquals(FaceTimeJoinOutcome.CLICKED, decision.outcome)
        assertTrue(decision.revealManualRecovery.not())
        assertFalse(decision.joined)
        assertTrue(decision.retry)
    }

    @Test
    fun visibleLeaveButtonIsNotConnectionEvidence() {
        val policy = FaceTimeJoinPolicy()

        val action = policy.record("\"already-joined\"")
        assertFalse(action.joined)
        val decision = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CHECKING,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = null,
                webLeaveVisible = true,
            )
        )

        assertTrue(policy.admissionRequested)
        assertFalse(decision.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_PENDING, decision.outcome)
    }

    @Test
    fun connectedIceAndRemoteAudioAdmitAudioOnlyCall() {
        val policy = FaceTimeJoinPolicy()
        policy.record("\"clicked\"")

        policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 0,
                mediaBytes = 64,
                webLeaveVisible = true,
                peerId = 1,
            )
        )

        val decision = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 0,
                mediaBytes = 128,
                webLeaveVisible = true,
                peerId = 1,
            )
        )

        assertTrue(decision.joined)
        assertFalse(decision.retry)
        assertEquals(FaceTimeJoinOutcome.MEDIA_CONNECTED, decision.outcome)
    }

    @Test
    fun failedIceDoesNotAdmitCall() {
        val policy = FaceTimeJoinPolicy()
        policy.record("\"clicked\"")

        val decision = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.FAILED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 0,
                webLeaveVisible = false,
            )
        )

        assertFalse(decision.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_FAILED, decision.outcome)
        assertTrue(decision.retry)
    }

    @Test
    fun oneFlatStatsIntervalKeepsAnAlreadyJoinedCallAdmitted() {
        val policy = FaceTimeJoinPolicy()
        policy.record("\"clicked\"")
        policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 512,
                webLeaveVisible = true,
                peerId = 1,
            )
        )
        assertTrue(policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 1024,
                webLeaveVisible = true,
                peerId = 1,
            )
        ).joined)

        val decision = policy.recordMediaEvidence(connectedEvidence(mediaBytes = 1024))

        assertTrue(decision.joined)
        assertTrue(policy.completedJoin)
        assertEquals(FaceTimeJoinOutcome.MEDIA_CONNECTED, decision.outcome)
        assertFalse(decision.retry)
    }

    @Test
    fun consecutiveFlatStatsIntervalsEventuallyReportMediaFailure() {
        val policy = admittedPolicy()

        repeat(FaceTimeConnectionProbePolicy.consecutiveStalledSamplesBeforeMediaLoss - 1) {
            assertTrue(policy.recordMediaEvidence(connectedEvidence(mediaBytes = 1024)).joined)
        }
        val stalled = policy.recordMediaEvidence(connectedEvidence(mediaBytes = 1024))

        assertFalse(stalled.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_FAILED, stalled.outcome)
        assertFalse(stalled.retry)
    }

    @Test
    fun advancingMediaResetsTheStallHysteresis() {
        val policy = admittedPolicy()

        assertTrue(policy.recordMediaEvidence(connectedEvidence(mediaBytes = 1024)).joined)
        assertTrue(policy.recordMediaEvidence(connectedEvidence(mediaBytes = 1024)).joined)
        assertTrue(policy.recordMediaEvidence(connectedEvidence(mediaBytes = 2048)).joined)
        repeat(FaceTimeConnectionProbePolicy.consecutiveStalledSamplesBeforeMediaLoss - 1) {
            assertTrue(policy.recordMediaEvidence(connectedEvidence(mediaBytes = 2048)).joined)
        }
    }

    @Test
    fun terminalIceFailureStillDemotesAnAdmittedCallImmediately() {
        val policy = admittedPolicy()

        val decision = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.FAILED,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = null,
                webLeaveVisible = false,
            ),
        )

        assertFalse(decision.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_FAILED, decision.outcome)
    }

    @Test
    fun advancingEncryptedTransportDoesNotAdmitWhenDecodedVideoIsFlat() {
        val policy = FaceTimeJoinPolicy()

        policy.recordMediaEvidence(decodedVideoEvidence(mediaBytes = 100, framesDecoded = 0))
        val transportOnly = policy.recordMediaEvidence(
            decodedVideoEvidence(mediaBytes = 200, framesDecoded = 0),
        )
        val decoded = policy.recordMediaEvidence(
            decodedVideoEvidence(mediaBytes = 300, framesDecoded = 1),
        )

        assertFalse(transportOnly.joined)
        assertTrue(decoded.joined)
    }

    @Test
    fun advancingNonConcealedAudioSamplesCanAdmitAudioOnlyMedia() {
        val policy = FaceTimeJoinPolicy()

        policy.recordMediaEvidence(decodedAudioEvidence(mediaBytes = 100, samples = 1000, concealed = 100))
        val concealedOnly = policy.recordMediaEvidence(
            decodedAudioEvidence(mediaBytes = 200, samples = 1100, concealed = 200),
        )
        val decoded = policy.recordMediaEvidence(
            decodedAudioEvidence(mediaBytes = 300, samples = 1300, concealed = 250),
        )

        assertFalse(concealedOnly.joined)
        assertTrue(decoded.joined)
    }

    @Test
    fun decodedCountersCanAdmitWhenTransportBytesAreUnavailable() {
        val policy = FaceTimeJoinPolicy()

        policy.recordMediaEvidence(
            decodedVideoEvidence(mediaBytes = null, framesDecoded = 10),
        )
        val decoded = policy.recordMediaEvidence(
            decodedVideoEvidence(mediaBytes = null, framesDecoded = 11),
        )

        assertTrue(decoded.joined)
        assertEquals(FaceTimeJoinOutcome.MEDIA_CONNECTED, decoded.outcome)
    }

    @Test
    fun delayedEvidenceCanAdmitAfterMultipleJoinAttempts() {
        val policy = FaceTimeJoinPolicy(manualRecoveryAttempt = 2, maxAttempts = 4)

        assertFalse(policy.record("\"missing\"").joined)
        assertFalse(policy.record("\"clicked\"").joined)
        policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.COMPLETED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 1024,
                webLeaveVisible = true,
                peerId = 1,
            )
        )
        assertTrue(policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.COMPLETED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 2048,
                webLeaveVisible = true,
                peerId = 1,
            )
        ).joined)
    }

    @Test
    fun retriesEventuallyStopWithoutClaimingJoined() {
        val policy = FaceTimeJoinPolicy(manualRecoveryAttempt = 1, maxAttempts = 2)

        policy.record("\"disabled\"")
        val finalDecision = policy.record(null)

        assertEquals(FaceTimeJoinOutcome.UNKNOWN, finalDecision.outcome)
        assertTrue(finalDecision.revealManualRecovery)
        assertFalse(finalDecision.retry)
        assertFalse(finalDecision.joined)
    }

    @Test
    fun duplicateIntentDoesNotReplaceActiveCall() {
        val lifecycle = FaceTimeCallLifecycle()

        assertEquals(FaceTimeIntentDisposition.ACCEPTED, lifecycle.acceptIntent("call-a"))
        assertEquals(FaceTimeIntentDisposition.DUPLICATE, lifecycle.acceptIntent("call-a"))
        assertEquals(
            FaceTimeIntentDisposition.REJECTED_MISMATCHED_CALL,
            lifecycle.acceptIntent("call-b"),
        )
        assertEquals(
            FaceTimeIntentDisposition.REJECTED_MISSING_CALL_ID,
            lifecycle.acceptIntent(null),
        )
    }

    @Test
    fun lifecycleCanAcceptNewCallAfterReset() {
        val lifecycle = FaceTimeCallLifecycle()

        lifecycle.acceptIntent("call-a")
        lifecycle.reset()

        assertEquals(FaceTimeIntentDisposition.ACCEPTED, lifecycle.acceptIntent("call-b"))
    }

    @Test
    fun nativeEndIsSuppressedWheneverTheWebLeaveControlIsVisible() {
        assertFalse(FaceTimeControlPolicy.shouldShowNativeEndControl(false, webLeaveObservationFresh = false))
        assertTrue(FaceTimeControlPolicy.shouldShowNativeEndControl(false, webLeaveObservationFresh = true))
        assertFalse(FaceTimeControlPolicy.shouldShowNativeEndControl(true, webLeaveObservationFresh = true))
        assertEquals(FaceTimeNativeEndPlacement.TOP_RIGHT, FaceTimeControlPolicy.nativeEndPlacement())
    }

    @Test
    fun connectionProbeWindowAllowsLateMediaWithoutExtendingJoinRetries() {
        assertEquals(80, FaceTimeConnectionProbePolicy.maxProbes)
        assertTrue(FaceTimeConnectionProbePolicy.pendingDelayMillis in 750L..1500L)
        assertTrue(FaceTimeConnectionProbePolicy.initialDelayMillis < FaceTimeConnectionProbePolicy.pendingDelayMillis)
        assertTrue(FaceTimeConnectionProbePolicy.consecutiveStalledSamplesBeforeMediaLoss >= 2)
    }

    private fun admittedPolicy(): FaceTimeJoinPolicy {
        val policy = FaceTimeJoinPolicy()
        policy.recordMediaEvidence(connectedEvidence(mediaBytes = 512))
        assertTrue(policy.recordMediaEvidence(connectedEvidence(mediaBytes = 1024)).joined)
        return policy
    }

    private fun connectedEvidence(mediaBytes: Long) = FaceTimeMediaEvidence(
        iceState = FaceTimeIceState.CONNECTED,
        remoteAudioTracks = 1,
        remoteVideoTracks = 1,
        mediaBytes = mediaBytes,
        webLeaveVisible = true,
        peerId = 1,
    )

    private fun decodedVideoEvidence(mediaBytes: Long?, framesDecoded: Long) = FaceTimeMediaEvidence(
        iceState = FaceTimeIceState.CONNECTED,
        remoteAudioTracks = 0,
        remoteVideoTracks = 1,
        mediaBytes = mediaBytes,
        webLeaveVisible = true,
        peerId = 1,
        videoFramesDecoded = framesDecoded,
    )

    private fun decodedAudioEvidence(mediaBytes: Long, samples: Long, concealed: Long) = FaceTimeMediaEvidence(
        iceState = FaceTimeIceState.CONNECTED,
        remoteAudioTracks = 1,
        remoteVideoTracks = 0,
        mediaBytes = mediaBytes,
        webLeaveVisible = true,
        peerId = 1,
        audioSamplesReceived = samples,
        audioConcealedSamples = concealed,
        audioJitterBufferEmittedCount = samples,
    )
}
