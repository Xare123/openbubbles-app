package com.bluebubbles.messaging.services.rustpush

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudSyncV2WorkPolicyTest {
    @Test
    fun `durable scheduling gate is closed by default`() {
        assertFalse(CloudSyncV2WorkScheduler.schedulingEnabled)
    }

    @Test
    fun `metadata work is battery safe and coalesces for fifteen seconds`() {
        val policy = CloudSyncV2WorkPolicy.forKind(CloudSyncV2WorkKind.METADATA)

        assertEquals(CloudSyncV2NetworkRequirement.CONNECTED, policy.networkRequirement)
        assertTrue(policy.requiresBatteryNotLow)
        assertTrue(policy.requiresStorageNotLow)
        assertEquals(15_000L, policy.initialDelayMillis)
        assertFalse(policy.requestsExpeditedExecution)
    }

    @Test
    fun `automatic media requires unmetered network`() {
        val policy = CloudSyncV2WorkPolicy.forKind(CloudSyncV2WorkKind.AUTOMATIC_MEDIA)

        assertEquals(CloudSyncV2NetworkRequirement.UNMETERED, policy.networkRequirement)
        assertTrue(policy.requiresBatteryNotLow)
        assertTrue(policy.requiresStorageNotLow)
        assertFalse(policy.requestsExpeditedExecution)
    }

    @Test
    fun `user visible work is explicitly modeled but never expedited`() {
        val policy = CloudSyncV2WorkPolicy.forKind(CloudSyncV2WorkKind.USER_VISIBLE_MANUAL)

        assertEquals(CloudSyncV2NetworkRequirement.CONNECTED, policy.networkRequirement)
        assertFalse(policy.requestsExpeditedExecution)
    }

    @Test
    fun `unique work name hashes the complete scope and does not expose it`() {
        val scope = "account-fingerprint\u001fcontainer\u001fprivate\u001fzone\u001fmessages\u001f2"
        val name = CloudSyncV2WorkScheduler.uniqueWorkNameForScopeKey(scope)

        assertTrue(name.startsWith("cloud-sync-v2/"))
        assertFalse(name.contains("account-fingerprint"))
        assertNotEquals(
            name,
            CloudSyncV2WorkScheduler.uniqueWorkNameForScopeKey("$scope-other"),
        )
    }
}
