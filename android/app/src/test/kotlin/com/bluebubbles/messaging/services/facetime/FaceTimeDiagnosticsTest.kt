package com.bluebubbles.messaging.services.facetime

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
}
