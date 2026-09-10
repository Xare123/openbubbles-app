package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeDiagnosticsTest {
    @Test
    fun diagnosticsRequireDeveloperModeAndExplicitOptIn() {
        assertFalse(FaceTimeDiagnosticPolicy.shouldEnable(false, false))
        assertFalse(FaceTimeDiagnosticPolicy.shouldEnable(false, true))
        assertFalse(FaceTimeDiagnosticPolicy.shouldEnable(true, false))
        assertTrue(FaceTimeDiagnosticPolicy.shouldEnable(true, true))
    }

    @Test
    fun structuredStagesContainOnlyRedactedFields() {
        val line = FaceTimeDiagnosticPolicy.formatStage(
            stage = FaceTimeDiagnosticStage.MEDIA_BYTES,
            count = 2,
            bytes = 4096,
        )

        assertEquals("stage=media_bytes bytes=4096", line)
        assertFalse(line.contains("http", ignoreCase = true))
        assertFalse(line.contains("sdp", ignoreCase = true))
    }

    @Test
    fun unknownIceStateIsRedacted() {
        assertEquals("connected", FaceTimeDiagnosticPolicy.safeState(FaceTimeDiagnosticStage.ICE_STATE, "Connected"))
        assertEquals("unknown", FaceTimeDiagnosticPolicy.safeState(FaceTimeDiagnosticStage.ICE_STATE, "secret-token"))
    }
}
