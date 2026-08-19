package com.bluebubbles.messaging.services.facetime

import android.content.pm.ServiceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeWebPolicyTest {
    @Test
    fun onlyAllowsTheOriginalHttpsOrigin() {
        val origin = secureWebOrigin("https://facetime.apple.com/join/example")

        assertTrue(matchesWebOrigin(origin, "https://facetime.apple.com:443/call"))
        assertFalse(matchesWebOrigin(origin, "http://facetime.apple.com/call"))
        assertFalse(matchesWebOrigin(origin, "https://example.com/call"))
        assertEquals(null, secureWebOrigin("http://facetime.apple.com/call"))
    }

    @Test
    fun javascriptStringsCannotEscapeTheirLiteral() {
        assertEquals("\"Rami \\\"RJ\\\"\\n\\\\test\"", javascriptStringLiteral("Rami \"RJ\"\n\\test"))
        assertEquals("\"line\\u2028break\"", javascriptStringLiteral("line\u2028break"))
    }

    @Test
    fun permissionDecisionWaitsForASeparateSecondPrompt() {
        val required = setOf("camera", "microphone")

        assertEquals(
            FaceTimePermissionDecision.WAIT,
            faceTimePermissionDecision(required, setOf("camera"), emptySet()),
        )
        assertEquals(
            FaceTimePermissionDecision.GRANT,
            faceTimePermissionDecision(required, required, emptySet()),
        )
        assertEquals(
            FaceTimePermissionDecision.DENY,
            faceTimePermissionDecision(required, setOf("camera"), setOf("microphone")),
        )
    }

    @Test
    fun foregroundServiceTypeUpgradesWhenMicrophoneIsGrantedLater() {
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            faceTimeForegroundServiceType(
                hasCameraPermission = true,
                hasMicrophonePermission = false,
            ),
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            faceTimeForegroundServiceType(
                hasCameraPermission = true,
                hasMicrophonePermission = true,
            ),
        )
    }
}
