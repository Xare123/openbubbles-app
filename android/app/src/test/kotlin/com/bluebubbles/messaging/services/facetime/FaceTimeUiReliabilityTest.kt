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
}
