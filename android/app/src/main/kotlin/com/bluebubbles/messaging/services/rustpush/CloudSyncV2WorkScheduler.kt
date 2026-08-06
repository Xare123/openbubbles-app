package com.bluebubbles.messaging.services.rustpush

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Android-side durable scheduling boundary for Cloud Sync V2.
 *
 * The default gate is closed. IDS/APNs callers may eventually submit a hint to
 * this class, but must return immediately and never perform CloudKit work on
 * that latency-sensitive path. WorkManager's unique-work KEEP semantics only
 * coalesce wake hints; it never replaces ObjectBox coordinator leases.
 */
internal object CloudSyncV2WorkScheduler {
    const val INPUT_SCOPE_HASH = "cloud_sync_v2_scope_hash"
    const val INPUT_WORK_KIND = "cloud_sync_v2_work_kind"
    private const val UNIQUE_WORK_PREFIX = "cloud-sync-v2/"

    /** Closed unless a future reviewed composition explicitly opens it. */
    @Volatile
    var schedulingEnabled: Boolean = false

    fun enqueueHint(
        context: Context,
        scopeKey: String,
        kind: CloudSyncV2WorkKind = CloudSyncV2WorkKind.METADATA,
    ): Boolean {
        if (!schedulingEnabled) return false

        val scopeHash = hashScope(scopeKey)
        val policy = CloudSyncV2WorkPolicy.forKind(kind)
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(
                when (policy.networkRequirement) {
                    CloudSyncV2NetworkRequirement.CONNECTED -> NetworkType.CONNECTED
                    CloudSyncV2NetworkRequirement.UNMETERED -> NetworkType.UNMETERED
                },
            )
            .setRequiresBatteryNotLow(policy.requiresBatteryNotLow)
            .setRequiresStorageNotLow(policy.requiresStorageNotLow)
            .build()

        val request = OneTimeWorkRequestBuilder<CloudSyncV2Worker>()
            .setConstraints(constraints)
            .setInitialDelay(policy.initialDelayMillis, TimeUnit.MILLISECONDS)
            .setInputData(
                androidx.work.Data.Builder()
                    .putString(INPUT_SCOPE_HASH, scopeHash)
                    .putString(INPUT_WORK_KIND, kind.name)
                    .build(),
            )
            .addTag(UNIQUE_WORK_PREFIX + scopeHash)
            // Do not use setExpedited. Even USER_VISIBLE_MANUAL remains normal
            // work until a separately reviewed foreground/user-visible design
            // can prove Android policy compliance.
            .build()

        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            uniqueWorkName(scopeHash),
            ExistingWorkPolicy.KEEP,
            request,
        )
        return true
    }

    fun cancel(context: Context, scopeKey: String) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(
            uniqueWorkName(hashScope(scopeKey)),
        )
    }

    internal fun uniqueWorkNameForScopeKey(scopeKey: String): String =
        uniqueWorkName(hashScope(scopeKey))

    internal fun hashScope(scopeKey: String): String {
        require(scopeKey.isNotBlank()) { "Cloud Sync V2 scope key must not be blank" }
        return MessageDigest.getInstance("SHA-256")
            .digest(scopeKey.toByteArray(Charsets.UTF_8))
            .joinToString(separator = "") { byte ->
                "%02x".format(byte.toInt() and 0xff)
            }
    }

    private fun uniqueWorkName(scopeHash: String): String = UNIQUE_WORK_PREFIX + scopeHash
}
