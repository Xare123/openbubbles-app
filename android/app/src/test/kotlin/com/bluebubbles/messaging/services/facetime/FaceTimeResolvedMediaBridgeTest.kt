package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeResolvedMediaBridgeTest {
    @Test
    fun requestScriptAwaitsSnapshotAndUsesBoundedNativeCallback() {
        val script = FaceTimeResolvedMediaBridge.requestScript(17)

        assertTrue(script.contains("Promise.resolve(window.__obFaceTimeDiagnostics.snapshot())"))
        assertTrue(script.contains("window.__obFaceTimeNativeEvent?.(\"media-evidence\", String(probeId), payload)"))
        assertFalse(script.contains("Native.mediaEvidence"))
        assertTrue(script.contains("const probeId = 17"))
        assertTrue(script.contains("return \"requested\""))
    }

    @Test
    fun callbackTimeoutIsFinite() {
        assertTrue(FaceTimeResolvedMediaBridge.callbackTimeoutMillis in 1_000L..5_000L)
    }

    @Test
    fun callbackGateAcceptsOnlyTheExpectedProbeOnce() {
        val gate = FaceTimeResolvedMediaCallbackGate()

        assertTrue(gate.expect(17))
        assertFalse(gate.accept(16, "stale"))
        assertTrue(gate.accept(17, "current"))
        assertFalse(gate.accept(17, "duplicate"))
        assertFalse(gate.accept(18, "unknown"))
    }

    @Test
    fun callbackGateRejectsFloodsOversizedPayloadsAndCancelledProbes() {
        val gate = FaceTimeResolvedMediaCallbackGate()
        val payload = "x".repeat(FaceTimeResolvedMediaBridge.maxCallbackPayloadLength + 1)

        assertTrue(gate.expect(5))
        assertFalse(gate.accept(5, payload))
        assertTrue(gate.accept(5, "first valid callback"))
        repeat(10) { assertFalse(gate.accept(5, "flood")) }

        assertTrue(gate.expect(6))
        gate.cancel(6)
        assertFalse(gate.accept(6, "late after timeout"))

        assertTrue(gate.expect(7))
        gate.reset()
        assertFalse(gate.accept(7, "late after lifecycle teardown"))
    }

    @Test
    fun newerProbeInvalidatesAnOlderCallbackBeforeItCanReachTheMainThread() {
        val gate = FaceTimeResolvedMediaCallbackGate()

        assertTrue(gate.expect(10))
        assertTrue(gate.expect(11))
        assertFalse(gate.accept(10, "late superseded callback"))
        assertTrue(gate.accept(11, "current callback"))
    }

    @Test
    fun leaveVisibilityGateDeduplicatesAndPrioritizesImmediateHiding() {
        val gate = FaceTimeWebLeaveVisibilityGate()

        assertEquals(false, gate.accept("false"))
        assertNull(gate.accept("false"))
        assertEquals(true, gate.accept("true"))
        assertNull(gate.accept("true"))
        assertEquals(false, gate.accept("false"))
    }

    @Test
    fun leaveVisibilityGateRejectsMalformedAndDeduplicatesStableStates() {
        val gate = FaceTimeWebLeaveVisibilityGate()

        assertNull(gate.accept(null))
        assertNull(gate.accept("TRUE"))
        assertNull(gate.accept("true".repeat(10_000)))
        assertEquals(false, gate.accept("false"))
        repeat(1_000) { assertNull(gate.accept("false")) }
        assertEquals(true, gate.accept("true"))
        repeat(1_000) { assertNull(gate.accept("true")) }
    }

    @Test
    fun leaveVisibilityGateLifecycleResetDropsPriorDeduplicationState() {
        val gate = FaceTimeWebLeaveVisibilityGate()

        assertEquals(true, gate.accept("true"))
        gate.reset()
        assertEquals(false, gate.accept("false"))
    }
}
