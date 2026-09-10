package com.bluebubbles.messaging.services.rustpush

/**
 * Pure scheduling policy for the dormant Cloud Sync V2 Android adapter.
 *
 * This is intentionally independent of WorkManager so its safety invariants
 * can be tested without starting Android framework code. It is a scheduling
 * policy only: it does not authorize a CloudKit operation.
 */
internal enum class CloudSyncV2WorkKind {
    METADATA,
    AUTOMATIC_MEDIA,
    USER_VISIBLE_MANUAL,
}

internal enum class CloudSyncV2NetworkRequirement {
    CONNECTED,
    UNMETERED,
}

internal enum class CloudSyncV2WorkerDisposition {
    SUCCESS,
    RETRY,
    FAILURE,
}

internal object CloudSyncV2WorkOutcomePolicy {
    const val MAX_ATTEMPTS = 5

    fun resolve(outcome: String?, runAttemptCount: Int): CloudSyncV2WorkerDisposition =
        when (outcome) {
            "complete", "stale" -> CloudSyncV2WorkerDisposition.SUCCESS
            "retry" -> if (runAttemptCount + 1 >= MAX_ATTEMPTS) {
                CloudSyncV2WorkerDisposition.FAILURE
            } else {
                CloudSyncV2WorkerDisposition.RETRY
            }
            else -> CloudSyncV2WorkerDisposition.FAILURE
        }
}

internal data class CloudSyncV2WorkPolicy(
    val networkRequirement: CloudSyncV2NetworkRequirement,
    val requiresBatteryNotLow: Boolean = true,
    val requiresStorageNotLow: Boolean = true,
    val initialDelayMillis: Long = CloudSyncV2WorkPolicy.COALESCE_DELAY_MILLIS,
    /**
     * Kept explicit so a future user-visible flow cannot accidentally become
     * expedited. V2 currently never requests expedited execution.
     */
    val requestsExpeditedExecution: Boolean = false,
) {
    companion object {
        const val COALESCE_DELAY_MILLIS = 15_000L

        fun forKind(kind: CloudSyncV2WorkKind): CloudSyncV2WorkPolicy = when (kind) {
            CloudSyncV2WorkKind.METADATA,
            CloudSyncV2WorkKind.USER_VISIBLE_MANUAL ->
                CloudSyncV2WorkPolicy(CloudSyncV2NetworkRequirement.CONNECTED)
            CloudSyncV2WorkKind.AUTOMATIC_MEDIA ->
                CloudSyncV2WorkPolicy(CloudSyncV2NetworkRequirement.UNMETERED)
        }
    }
}
