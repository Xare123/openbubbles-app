package com.bluebubbles.messaging.services.rustpush

import android.content.pm.ApplicationInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudSyncV2WorkRegistrationTest {
    @Test
    fun `backend package requires the actual debuggable flag`() {
        val backend = "com.bluebubbles.messaging.backendtest"
        assertFalse(CloudSyncV2WorkRegistration.isAllowedPackage(backend, 0))
        assertFalse(CloudSyncV2WorkRegistration.isAllowedPackage(backend, ApplicationInfo.FLAG_HAS_CODE))
        assertTrue(CloudSyncV2WorkRegistration.isAllowedPackage(backend, ApplicationInfo.FLAG_DEBUGGABLE))
        assertTrue(CloudSyncV2WorkRegistration.isAllowedPackage(
            backend, ApplicationInfo.FLAG_HAS_CODE or ApplicationInfo.FLAG_DEBUGGABLE,
        ))
    }

    @Test
    fun `Canary retains admission in debug and release`() {
        val canary = "com.bluebubbles.messaging.cloudkitcanary"
        assertTrue(CloudSyncV2WorkRegistration.isAllowedPackage(canary, 0))
        assertTrue(CloudSyncV2WorkRegistration.isAllowedPackage(canary, ApplicationInfo.FLAG_DEBUGGABLE))
    }

    @Test
    fun `other packages remain closed even when debuggable`() {
        for (packageName in listOf(
            "com.bluebubbles.messaging",
            "com.openbubbles.messaging",
            "com.bluebubbles.messaging.alpha",
            "com.bluebubbles.messaging.beta",
            "com.bluebubbles.messaging.backendtest.debug",
            "com.bluebubbles.messaging.backendtest.other",
            "com.bluebubbles.messaging.cloudkitcanary.other",
            "COM.BLUEBUBBLES.MESSAGING.BACKENDTEST",
            "",
        )) {
            assertFalse(packageName, CloudSyncV2WorkRegistration.isAllowedPackage(packageName, 0))
            assertFalse(packageName, CloudSyncV2WorkRegistration.isAllowedPackage(
                packageName, ApplicationInfo.FLAG_DEBUGGABLE,
            ))
        }
    }
}
