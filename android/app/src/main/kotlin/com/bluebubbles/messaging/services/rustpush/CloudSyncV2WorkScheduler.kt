package com.bluebubbles.messaging.services.rustpush

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.guava.await

/**
 * Android-side durable scheduling boundary for Cloud Sync V2.
 *
 * The default gate is closed. IDS/APNs callers may eventually submit a hint to
 * this class, but must return immediately and never perform CloudKit work on
 * that latency-sensitive path. The persisted wake coordinator coalesces hints;
 * WorkManager never replaces ObjectBox coordinator leases.
 */
internal object CloudSyncV2WorkScheduler {
    const val INPUT_SCOPE_HASH = "cloud_sync_v2_scope_hash"
    const val INPUT_WORK_KIND = "cloud_sync_v2_work_kind"
    const val INPUT_REGISTRATION_EPOCH = "cloud_sync_v2_registration_epoch"
    private const val UNIQUE_WORK_PREFIX = "cloud-sync-v2/"

    suspend fun enqueue(context: Context, record: CloudSyncV2WakeRecord) {
        require(context.packageName == CloudSyncV2WorkRegistration.CANARY_PACKAGE)
        val scopeHash = requireNotNull(record.scopeHash)
        val workId = requireNotNull(record.workId)
        require(CloudSyncV2WorkRegistration.isCanonicalScopeHash(scopeHash) && record.epoch > 0)
        val policy = CloudSyncV2WorkPolicy.forKind(CloudSyncV2WorkKind.METADATA)
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
            .setId(workId)
            .setConstraints(constraints)
            .setInitialDelay(policy.initialDelayMillis, TimeUnit.MILLISECONDS)
            .setInputData(
                androidx.work.Data.Builder()
                    .putString(INPUT_SCOPE_HASH, scopeHash)
                    .putString(INPUT_WORK_KIND, CloudSyncV2WorkKind.METADATA.name)
                    .putLong(INPUT_REGISTRATION_EPOCH, record.epoch)
                    .build(),
            )
            .addTag(UNIQUE_WORK_PREFIX + scopeHash)
            // Do not use setExpedited. Even USER_VISIBLE_MANUAL remains normal
            // work until a separately reviewed foreground/user-visible design
            // can prove Android policy compliance.
            .build()

        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            "${uniqueWorkName(scopeHash)}/${record.epoch}/$workId",
            ExistingWorkPolicy.KEEP,
            request,
        ).result.await()
    }

    suspend fun unfinished(context: Context, workId: UUID): Boolean? =
        WorkManager.getInstance(context.applicationContext)
            .getWorkInfoById(workId).await()?.state?.let { !it.isFinished }

    suspend fun cancel(context: Context, workId: UUID) {
        WorkManager.getInstance(context.applicationContext).cancelWorkById(workId).result.await()
    }

    internal fun uniqueWorkNameForScopeHash(scopeHash: String): String {
        require(CloudSyncV2WorkRegistration.isCanonicalScopeHash(scopeHash))
        return uniqueWorkName(scopeHash)
    }

    private fun uniqueWorkName(scopeHash: String): String = UNIQUE_WORK_PREFIX + scopeHash
}
