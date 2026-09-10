package com.bluebubbles.messaging.services.rustpush

import android.content.Context
import android.util.Log
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorker
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.guava.future
import kotlinx.coroutines.withTimeout

/**
 * Bounded read-only Cloud Sync V2 handoff for the Canary package.
 *
 * WorkManager provides durable wake/retry only. Dart still revalidates the
 * complete account scope and ObjectBox's coordinator/interlock remains the
 * sole authority that may run the semantic read.
 */
class CloudSyncV2Worker(
    appContext: Context,
    params: WorkerParameters,
) : ListenableWorker(appContext, params) {
    companion object {
        private const val EXECUTION_TIMEOUT_MILLIS = 8L * 60L * 1000L
        private const val DART_METHOD = "cloud-sync-v2-background-wake"
    }

    override fun startWork(): ListenableFuture<Result> =
        CoroutineScope(Dispatchers.Main.immediate).future {
            val scopeHash = inputData.getString(CloudSyncV2WorkScheduler.INPUT_SCOPE_HASH)
            val kindValue = inputData.getString(CloudSyncV2WorkScheduler.INPUT_WORK_KIND)
            if (!CloudSyncV2WorkRegistration.isCanonicalScopeHash(scopeHash) ||
                kindValue.isNullOrBlank()) {
                Log.w(Constants.logTag, "Cloud Sync V2 work rejected: invalid safe input")
                return@future Result.failure()
            }
            if (!CloudSyncV2WorkRegistration.matches(applicationContext, scopeHash!!)) {
                Log.i(Constants.logTag, "Cloud Sync V2 stale durable wake discarded")
                return@future Result.success()
            }
            val kind = runCatching { CloudSyncV2WorkKind.valueOf(kindValue) }.getOrNull()
            if (kind != CloudSyncV2WorkKind.METADATA) {
                Log.w(Constants.logTag, "Cloud Sync V2 unsupported durable wake discarded")
                return@future Result.success()
            }
            if (runAttemptCount >= CloudSyncV2WorkOutcomePolicy.MAX_ATTEMPTS) {
                Log.w(Constants.logTag, "Cloud Sync V2 durable wake exhausted retry budget")
                return@future Result.failure()
            }

            val outcome = try {
                withTimeout(EXECUTION_TIMEOUT_MILLIS) {
                    DartWorker.callMethodForOutcome(
                        applicationContext,
                        DART_METHOD,
                        mapOf("scopeHash" to scopeHash, "kind" to kind.name),
                    )
                }
            } catch (_: TimeoutCancellationException) {
                "retry"
            } catch (_: Exception) {
                "retry"
            }

            when (CloudSyncV2WorkOutcomePolicy.resolve(outcome, runAttemptCount)) {
                CloudSyncV2WorkerDisposition.SUCCESS -> Result.success()
                CloudSyncV2WorkerDisposition.RETRY -> Result.retry()
                CloudSyncV2WorkerDisposition.FAILURE -> Result.failure()
            }
        }
}
