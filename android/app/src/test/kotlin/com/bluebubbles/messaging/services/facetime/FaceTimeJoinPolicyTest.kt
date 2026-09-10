package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeJoinPolicyTest {
    @Test
    fun lateAndDuplicateTimeoutsCannotDestroyTheNextCall() {
        var cachedCall: String? = "call-a"
        var activityCall: String? = null
        val destroyedPages = mutableListOf<String>()
        val finishedActivities = mutableListOf<String>()
        fun timeout(eventCall: String?) {
            if (FaceTimeTimeoutPolicy.matchesCall(eventCall, cachedCall)) {
                destroyedPages.add(cachedCall!!)
                cachedCall = null
            }
            if (FaceTimeTimeoutPolicy.shouldFinishActivity(eventCall, activityCall, false, true)) {
                finishedActivities.add(activityCall!!)
                activityCall = null
            }
        }

        // A ends, B preloads, then a duplicate/delayed A terminal event arrives.
        timeout("call-a")
        cachedCall = "call-b"
        timeout("call-a")
        assertEquals("call-b", cachedCall)
        assertEquals(listOf("call-a"), destroyedPages)

        // B takes ownership of its page; a further A event cannot finish B.
        activityCall = cachedCall
        cachedCall = null
        timeout("call-a")
        assertEquals("call-b", activityCall)
        assertTrue(finishedActivities.isEmpty())

        // Legitimate B cleanup still works, and a duplicate is harmless.
        timeout("call-b")
        timeout("call-b")
        assertEquals(null, activityCall)
        assertEquals(listOf("call-b"), finishedActivities)
    }

    @Test
    fun timeoutRequiresAnExactNonblankIdentityOnBothSides() {
        for (eventCall in listOf(null, "", " ", "\t", "call-a", "call-b ", "CALL-B")) {
            assertFalse(FaceTimeTimeoutPolicy.matchesCall(eventCall, "call-b"))
            assertFalse(FaceTimeTimeoutPolicy.shouldFinishActivity(eventCall, "call-b", false, true))
        }
        for (missing in listOf(null, "", " ", "\t")) {
            assertFalse(FaceTimeTimeoutPolicy.matchesCall(missing, missing))
            assertFalse(FaceTimeTimeoutPolicy.matchesCall("call-b", missing))
            assertFalse(FaceTimeTimeoutPolicy.shouldFinishActivity("call-b", missing, false, true))
        }
        assertTrue(FaceTimeTimeoutPolicy.matchesCall("call-b", "call-b"))
    }

    @Test
    fun timeoutPreservesAnsweredCallsAndNonCallActivities() {
        assertTrue(FaceTimeTimeoutPolicy.shouldFinishActivity("call-b", "call-b", false, true))
        assertFalse(FaceTimeTimeoutPolicy.shouldFinishActivity("call-b", "call-b", true, true))
        assertFalse(FaceTimeTimeoutPolicy.shouldFinishActivity("call-b", "call-b", false, false))
        assertFalse(FaceTimeTimeoutPolicy.shouldFinishActivity("call-b", "call-b", true, false))
    }

    @Test
    fun timeoutChecksActivityAndCacheOwnershipIndependently() {
        // Finishing A does not discard a preloaded B, and clearing B does not end A.
        assertTrue(FaceTimeTimeoutPolicy.shouldFinishActivity("call-a", "call-a", false, true))
        assertFalse(FaceTimeTimeoutPolicy.matchesCall("call-a", "call-b"))
        assertFalse(FaceTimeTimeoutPolicy.shouldFinishActivity("call-b", "call-a", false, true))
        assertTrue(FaceTimeTimeoutPolicy.matchesCall("call-b", "call-b"))
    }

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
    fun mediaLossClearsJoinedButDoesNotBlindlyRetryAfterCompletedJoin() {
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
    fun nativeEndHasADedicatedRegionWithoutAnyDomInput() {
        assertTrue(FaceTimeControlPolicy.shouldShowNativeEndControl())
        assertEquals(FaceTimeNativeEndPlacement.BOTTOM_LEFT, FaceTimeControlPolicy.nativeEndPlacement())
        // Portrait, landscape, increased font size and system/cutout insets all leave a gap
        // between the WebView bottom and the top of the native control's measured bounds.
        for (height in listOf(80, 112, 224)) for (inset in listOf(0, 24, 96)) {
            val reserved = FaceTimeControlPolicy.reservedBottomPixels(height, 12, inset)
            val nativeTopFromBottom = height + 12 + inset
            assertTrue(reserved > nativeTopFromBottom)
        }
        assertEquals(0, FaceTimeControlPolicy.reservedBottomPixels(-1, -1, -1))
    }

    @Test
    fun pipReleasesFooterThroughRepeatedProbesAndRestoresItOnExit() {
        for (height in listOf(80, 112, 224)) for (inset in listOf(0, 24, 96)) {
            // Fullscreen, PiP entry, repeated probe/layout updates, then PiP exit.
            for (pip in listOf(false, true, true, true, false)) {
                assertEquals(!pip, FaceTimeControlPolicy.shouldShowNativeEndControl(pip))
                assertEquals(
                    if (pip) 0 else height + 24 + inset,
                    FaceTimeControlPolicy.reservedBottomPixels(height, 12, inset, pip),
                )
            }
        }
    }

    @Test
    fun connectionProbeWindowAllowsLateMediaWithoutExtendingJoinRetries() {
        assertEquals(80, FaceTimeConnectionProbePolicy.maxProbes)
        assertTrue(FaceTimeConnectionProbePolicy.pendingDelayMillis in 750L..1500L)
        assertTrue(FaceTimeConnectionProbePolicy.initialDelayMillis < FaceTimeConnectionProbePolicy.pendingDelayMillis)
    }

    @Test
    fun pendingStatusDistinguishesPreparationAdmissionAndTransportFailure() {
        assertEquals(
            "Preparing FaceTime media...",
            FaceTimeConnectionStatusPolicy.pendingMessage(null, completedJoin = false),
        )
        assertEquals(
            "Waiting for FaceTime audio or video...",
            FaceTimeConnectionStatusPolicy.pendingMessage(
                FaceTimeMediaEvidence(
                    iceState = FaceTimeIceState.CONNECTED,
                    remoteAudioTracks = 0,
                    remoteVideoTracks = 0,
                    mediaBytes = 0,
                    webLeaveVisible = true,
                    peerId = 1,
                ),
                completedJoin = false,
            ),
        )
        assertEquals(
            "FaceTime connection failed. Tap Rejoin to retry.",
            FaceTimeConnectionStatusPolicy.pendingMessage(
                FaceTimeMediaEvidence(
                    iceState = FaceTimeIceState.FAILED,
                    remoteAudioTracks = 0,
                    remoteVideoTracks = 0,
                    mediaBytes = 0,
                    webLeaveVisible = true,
                    peerId = 1,
                ),
                completedJoin = false,
            ),
        )
    }

    @Test
    fun pendingStatusMakesPostConnectionMediaLossActionable() {
        assertEquals(
            "FaceTime media was interrupted. Tap Rejoin to retry.",
            FaceTimeConnectionStatusPolicy.pendingMessage(
                FaceTimeMediaEvidence(
                    iceState = FaceTimeIceState.DISCONNECTED,
                    remoteAudioTracks = 0,
                    remoteVideoTracks = 0,
                    mediaBytes = null,
                    webLeaveVisible = true,
                    peerId = 1,
                ),
                completedJoin = true,
            ),
        )
    }

    @Test
    fun preJoinDisconnectKeepsConnectingInsteadOfClaimingInterruption() {
        assertEquals(
            "Connecting FaceTime media...",
            FaceTimeConnectionStatusPolicy.pendingMessage(
                FaceTimeMediaEvidence(
                    iceState = FaceTimeIceState.DISCONNECTED,
                    remoteAudioTracks = 0,
                    remoteVideoTracks = 0,
                    mediaBytes = null,
                    webLeaveVisible = false,
                ),
                completedJoin = false,
            ),
        )
    }

    @Test
    fun closedTransportFailsEvenAfterACompletedJoin() {
        assertEquals(
            "FaceTime connection failed. Tap Rejoin to retry.",
            FaceTimeConnectionStatusPolicy.pendingMessage(
                FaceTimeMediaEvidence(
                    iceState = FaceTimeIceState.CLOSED,
                    remoteAudioTracks = 0,
                    remoteVideoTracks = 0,
                    mediaBytes = null,
                    webLeaveVisible = true,
                    peerId = 1,
                ),
                completedJoin = true,
            ),
        )
    }
}
