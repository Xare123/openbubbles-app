package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeActivityLaunchTest {
    @Test
    fun launchRequiresANonBlankFaceTimeLink() {
        assertFalse(hasRequiredFaceTimeLaunchData(null))
        assertFalse(hasRequiredFaceTimeLaunchData(""))
        assertFalse(hasRequiredFaceTimeLaunchData("   "))
        assertTrue(hasRequiredFaceTimeLaunchData("https://facetime.apple.com/join/example"))
    }
}
