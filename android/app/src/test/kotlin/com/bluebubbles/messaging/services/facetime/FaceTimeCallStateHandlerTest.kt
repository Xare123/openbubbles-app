package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeCallStateHandlerTest {
    @Test
    fun terminalStateClosesOnlyTheMatchingCallActivity() {
        assertTrue(shouldFinishFaceTimeActivity("timeout", true, "call-a", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("timeout", true, "call-b", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("ringing", true, "call-a", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("timeout", false, "call-a", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("timeout", true, "call-a", null))
    }
}
