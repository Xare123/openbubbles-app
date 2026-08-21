package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeCallStateHandlerTest {
    @Test
    fun timeoutClosesOnlyTheMatchingUnansweredCallActivity() {
        assertTrue(shouldFinishFaceTimeActivity("timeout", true, false, "call-a", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("timeout", true, true, "call-a", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("timeout", true, false, "call-b", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("ringing", true, false, "call-a", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("timeout", false, false, "call-a", "call-a"))
        assertFalse(shouldFinishFaceTimeActivity("timeout", true, false, "call-a", null))
    }
}
