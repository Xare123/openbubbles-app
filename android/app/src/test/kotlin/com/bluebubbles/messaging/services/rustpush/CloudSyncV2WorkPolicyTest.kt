package com.bluebubbles.messaging.services.rustpush

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudSyncV2WorkPolicyTest {
    @Test
    fun `durable registration accepts only a canonical lowercase scope hash`() {
        assertTrue(CloudSyncV2WorkRegistration.isCanonicalScopeHash("a".repeat(64)))
        assertFalse(CloudSyncV2WorkRegistration.isCanonicalScopeHash("A".repeat(64)))
        assertFalse(CloudSyncV2WorkRegistration.isCanonicalScopeHash("account-fingerprint"))
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
    fun `unique work name accepts only the already redacted scope hash`() {
        val hash = "0123456789abcdef".repeat(4)
        val name = CloudSyncV2WorkScheduler.uniqueWorkNameForScopeHash(hash)

        assertTrue(name.startsWith("cloud-sync-v2/"))
        assertEquals("cloud-sync-v2/$hash", name)
    }

    @Test
    fun `fixed worker outcomes are bounded and fail closed`() {
        assertEquals(
            CloudSyncV2WorkerDisposition.SUCCESS,
            CloudSyncV2WorkOutcomePolicy.resolve("complete", 0),
        )
        assertEquals(
            CloudSyncV2WorkerDisposition.SUCCESS,
            CloudSyncV2WorkOutcomePolicy.resolve("stale", 0),
        )
        assertEquals(
            CloudSyncV2WorkerDisposition.RETRY,
            CloudSyncV2WorkOutcomePolicy.resolve("retry", 0),
        )
        assertEquals(
            CloudSyncV2WorkerDisposition.FAILURE,
            CloudSyncV2WorkOutcomePolicy.resolve(
                "retry",
                CloudSyncV2WorkOutcomePolicy.MAX_ATTEMPTS - 1,
            ),
        )
        assertEquals(
            CloudSyncV2WorkerDisposition.FAILURE,
            CloudSyncV2WorkOutcomePolicy.resolve("unknown", 0),
        )
    }
}
