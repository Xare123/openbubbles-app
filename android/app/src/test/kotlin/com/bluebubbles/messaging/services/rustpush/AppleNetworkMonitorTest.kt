package com.bluebubbles.messaging.services.rustpush

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppleNetworkMonitorTest {
    @Test
    fun `local only network is not eligible for Apple Push`() {
        val snapshot = AppleNetworkSnapshot(
            network = null,
            hasInternet = false,
            validated = false,
        )

        assertFalse(snapshot.eligibleForApplePush)
    }

    @Test
    fun `internet without validation waits instead of forcing a refresh`() {
        val snapshot = AppleNetworkSnapshot(
            network = null,
            hasInternet = true,
            validated = false,
        )

        assertFalse(snapshot.eligibleForApplePush)
    }

    @Test
    fun `validated Internet network is eligible`() {
        val snapshot = AppleNetworkSnapshot(
            network = null,
            hasInternet = true,
            validated = true,
        )

        assertTrue(snapshot.eligibleForApplePush)
    }
}
