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

        val decision = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 0,
                mediaBytes = 128,
                webLeaveVisible = true,
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
    fun mediaLossClearsJoinedButDoesNotBlindlyRetryAfterCompletedJoin() {
        val policy = FaceTimeJoinPolicy()
        policy.record("\"clicked\"")
        assertTrue(policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.CONNECTED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 1024,
                webLeaveVisible = true,
            )
        ).joined)

        val decision = policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.DISCONNECTED,
                remoteAudioTracks = 0,
                remoteVideoTracks = 0,
                mediaBytes = null,
                webLeaveVisible = true,
            )
        )

        assertFalse(decision.joined)
        assertTrue(policy.completedJoin)
        assertEquals(FaceTimeJoinOutcome.MEDIA_PENDING, decision.outcome)
        assertFalse(decision.retry)
    }

    @Test
    fun delayedEvidenceCanAdmitAfterMultipleJoinAttempts() {
        val policy = FaceTimeJoinPolicy(manualRecoveryAttempt = 2, maxAttempts = 4)

        assertFalse(policy.record("\"missing\"").joined)
        assertFalse(policy.record("\"clicked\"").joined)
        assertTrue(policy.recordMediaEvidence(
            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.COMPLETED,
                remoteAudioTracks = 1,
                remoteVideoTracks = 1,
                mediaBytes = 2048,
                webLeaveVisible = true,
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
    fun nativeEndRemainsAvailableAndMovesAwayFromWebLeave() {
        assertTrue(FaceTimeControlPolicy.shouldShowNativeEndControl())
        assertEquals(FaceTimeNativeEndPlacement.TOP_RIGHT, FaceTimeControlPolicy.nativeEndPlacement(false))
        assertEquals(FaceTimeNativeEndPlacement.BOTTOM_LEFT, FaceTimeControlPolicy.nativeEndPlacement(true))
    }

    @Test
    fun connectionProbeWindowAllowsLateMediaWithoutExtendingJoinRetries() {
        assertEquals(80, FaceTimeConnectionProbePolicy.maxProbes)
        assertTrue(FaceTimeConnectionProbePolicy.pendingDelayMillis in 750L..1500L)
        assertTrue(FaceTimeConnectionProbePolicy.initialDelayMillis < FaceTimeConnectionProbePolicy.pendingDelayMillis)
    }
}
