package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeDiagnosticsTest {
    @Test
    fun diagnosticsRequireDeveloperModeAndExplicitOptIn() {
        assertFalse(FaceTimeDiagnostics.shouldEnable(false, false))
        assertFalse(FaceTimeDiagnostics.shouldEnable(false, true))
        assertFalse(FaceTimeDiagnostics.shouldEnable(true, false))
        assertTrue(FaceTimeDiagnostics.shouldEnable(true, true))
    }

    @Test
    fun structuredStagesContainOnlyRedactedFields() {
        val line = FaceTimeDiagnostics.formatStage(
            stage = FaceTimeDiagnosticStage.MEDIA_BYTES,
            state = "Connected",
            count = 2,
            bytes = 4096,
        )

        assertEquals("stage=media_bytes state=connected count=2 bytes=4096", line)
        assertFalse(line.contains("http", ignoreCase = true))
        assertFalse(line.contains("sdp", ignoreCase = true))
    }

    @Test
    fun unknownIceStateIsRedacted() {
        assertEquals("connected", FaceTimeDiagnostics.safeIceState("connected"))
        assertEquals("unknown", FaceTimeDiagnostics.safeIceState("secret-token"))
    }
}
