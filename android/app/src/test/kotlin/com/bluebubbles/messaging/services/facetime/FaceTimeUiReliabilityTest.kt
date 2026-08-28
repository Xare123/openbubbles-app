package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeUiReliabilityTest {
    @Test
    fun resolvedPromiseBridgeReportsConcretePayloadThroughNativeCallback() {
        val script = FaceTimeResolvedMediaBridge.requestScript(41)

        assertTrue(script.contains("Promise.resolve(window.__obFaceTimeDiagnostics.snapshot())"))
        assertTrue(script.contains(".then(report)"))
        assertTrue(script.contains("Native.mediaEvidence(String(probeId), payload)"))
        assertTrue(script.contains("const probeId = 41"))
        assertTrue(script.contains("return \"requested\""))
        assertFalse(script.contains("return window.__obFaceTimeDiagnostics.snapshot()"))
    }

    @Test
    fun localEndIsReportedExactlyOnceForTheActivityCall() {
        val reporter = FaceTimeLocalEndReporter()

        assertEquals("call-a", reporter.consume("call-a"))
        assertNull(reporter.consume("call-a"))
        assertNull(reporter.consume("call-b"))
    }

    @Test
    fun retryFalseOrErrorStateReenablesTheControl() {
        val state = FaceTimeAdmissionRetryState()

        assertTrue(state.begin())
        state.complete(false)
        assertFalse(state.inFlight)
        assertFalse(state.succeeded)
        assertTrue(state.begin())
        state.complete(false) // MethodChannel error/notImplemented maps to false.
        assertTrue(state.begin())
    }

    @Test
    fun successfulRetryRemainsSingleShot() {
        val state = FaceTimeAdmissionRetryState()

        assertTrue(state.begin())
        state.complete(true)
        assertTrue(state.succeeded)
        assertFalse(state.begin())
    }

    @Test
    fun retryDiagnosticsContainOnlyStableOutcome() {
        assertEquals("activity admission_retry result=false", FaceTimeResolvedMediaBridge.admissionRetryDiagnostic(false))
        assertEquals("activity admission_retry result=true", FaceTimeResolvedMediaBridge.admissionRetryDiagnostic(true))
    }

    @Test
    fun backAndLaterDestroyEmitOneWebLeave() {
        val policy = FaceTimeLifecycleEndPolicy()

        assertEquals(FaceTimeRemoteEndAction.WEB_LEAVE, policy.consume(FaceTimeLifecycleEndTrigger.BACK, active()))
        assertNull(policy.consume(FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY, active()))
    }

    @Test
    fun nativeEndThenExplicitWebCallbackDoesNotDoubleSend() {
        val policy = FaceTimeLifecycleEndPolicy()

        assertEquals(FaceTimeRemoteEndAction.WEB_LEAVE, policy.consume(FaceTimeLifecycleEndTrigger.NATIVE_END, active()))
        assertNull(policy.consume(FaceTimeLifecycleEndTrigger.EXPLICIT_WEB_LEAVE, active()))
    }

    @Test
    fun taskRemovalUsesTheOneShotWebLeavePath() {
        val policy = FaceTimeLifecycleEndPolicy()

        assertEquals(FaceTimeRemoteEndAction.WEB_LEAVE, policy.consume(FaceTimeLifecycleEndTrigger.TASK_REMOVAL, active()))
        assertNull(policy.consume(FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY, active()))
    }

    @Test
    fun unexpectedDestroyUsesTheOneShotWebLeavePath() {
        val policy = FaceTimeLifecycleEndPolicy()

        assertEquals(
            FaceTimeRemoteEndAction.WEB_LEAVE,
            policy.consume(FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY, active()),
        )
        assertTrue(policy.hasConsumedTerminalEvent)
    }

    @Test
    fun rendererDeathFailsClosedForAnsweredCallWithoutNativeCancelBinding() {
        val policy = FaceTimeLifecycleEndPolicy()

        assertEquals(
            FaceTimeRemoteEndAction.NO_SAFE_ACTION,
            policy.consume(
                FaceTimeLifecycleEndTrigger.RENDERER_GONE,
                active().copy(rendererAvailable = false),
            ),
        )
        assertNull(policy.consume(FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY, active()))
    }

    @Test
    fun unansweredIncomingRendererDeathUsesNativeDeclineExactlyOnce() {
        val policy = FaceTimeLifecycleEndPolicy()
        val incoming = active().copy(incomingCall = true, answered = false, rendererAvailable = false)

        assertEquals(
            FaceTimeRemoteEndAction.NATIVE_DECLINE,
            policy.consume(FaceTimeLifecycleEndTrigger.RENDERER_GONE, incoming),
        )
        assertNull(policy.consume(FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY, incoming))
    }

    @Test
    fun unansweredOutgoingCallNeverUsesIncomingDecline() {
        val policy = FaceTimeLifecycleEndPolicy()
        val outgoing = active().copy(incomingCall = false, answered = false)

        assertEquals(
            FaceTimeRemoteEndAction.WEB_LEAVE,
            policy.consume(FaceTimeLifecycleEndTrigger.BACK, outgoing),
        )
    }

    @Test
    fun explicitWebLeaveOwnsTheRemoteSideEffect() {
        val policy = FaceTimeLifecycleEndPolicy()

        assertEquals(
            FaceTimeRemoteEndAction.ALREADY_SENT,
            policy.consume(FaceTimeLifecycleEndTrigger.EXPLICIT_WEB_LEAVE, active()),
        )
        assertNull(policy.consume(FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY, active()))
    }

    @Test
    fun pictureInPictureAndConfigurationChangesDoNotConsumeTermination() {
        val policy = FaceTimeLifecycleEndPolicy()

        assertNull(
            policy.consume(
                FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY,
                active().copy(inPictureInPicture = true),
            ),
        )
        assertNull(
            policy.consume(
                FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY,
                active().copy(changingConfigurations = true),
            ),
        )
        assertFalse(policy.hasConsumedTerminalEvent)
        assertEquals(FaceTimeRemoteEndAction.WEB_LEAVE, policy.consume(FaceTimeLifecycleEndTrigger.BACK, active()))
    }

    @Test
    fun replacedActivityCannotEndTheCurrentCall() {
        val policy = FaceTimeLifecycleEndPolicy()

        assertNull(
            policy.consume(
                FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY,
                active().copy(currentActivity = false),
            ),
        )
        assertFalse(policy.hasConsumedTerminalEvent)
    }

    private fun active() = FaceTimeLifecycleEndSnapshot(
        activeCall = true,
        currentActivity = true,
        changingConfigurations = false,
        inPictureInPicture = false,
        incomingCall = false,
        answered = true,
        rendererAvailable = true,
    )
}
