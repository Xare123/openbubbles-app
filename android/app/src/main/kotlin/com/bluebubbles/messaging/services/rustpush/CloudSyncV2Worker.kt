package com.bluebubbles.messaging.services.rustpush

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.bluebubbles.messaging.Constants

/**
 * Durable WorkManager endpoint for the future Cloud Sync V2 handoff.
 *
 * This deliberately performs no CloudKit work. WorkManager preserves the
 * request across process death, but ObjectBox's coordinator lease remains the
 * only authority that may later claim and run a scoped sync. A future rollout
 * must add that lease-aware handoff behind its own reviewed feature gate.
 */
class CloudSyncV2Worker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {
    override fun doWork(): Result {
        val scopeHash = inputData.getString(CloudSyncV2WorkScheduler.INPUT_SCOPE_HASH)
        val kind = inputData.getString(CloudSyncV2WorkScheduler.INPUT_WORK_KIND)
        if (scopeHash.isNullOrBlank() || kind.isNullOrBlank()) {
            Log.w(Constants.logTag, "Cloud Sync V2 work rejected: missing safe scheduling input")
            return Result.failure()
        }

        // Deliberate no-op while V2 remains disabled. In particular, do not
        // initialize a Flutter engine or call Rust/CloudKit from this worker.
        Log.i(Constants.logTag, "Cloud Sync V2 durable handoff reached kind=$kind")
        return Result.success()
    }
}
