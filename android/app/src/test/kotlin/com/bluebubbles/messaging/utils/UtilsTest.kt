package com.bluebubbles.messaging.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UtilsTest {
    @Test
    fun portraitImageNeverProducesZeroWidth() {
        assertEquals(Pair(12, 72), Utils.calculateScaledDimensions(17, 102, 72))
    }

    @Test
    fun landscapeImageNeverProducesZeroHeight() {
        assertEquals(Pair(72, 12), Utils.calculateScaledDimensions(102, 17, 72))
    }

    @Test
    fun rejectsInvalidSourceDimensions() {
        assertNull(Utils.calculateScaledDimensions(0, 72, 72))
    }
}
