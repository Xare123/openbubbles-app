package com.bluebubbles.messaging.services.backend_ui_interop

import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.suspendCancellableCoroutine

/** Canceling a Kotlin waiter does not cancel an already-dispatched Dart future. */
internal object DartWorkerOutcomeCall {
    suspend fun awaitOutcome(
        invoke: (MethodChannel.Result) -> Unit,
        releaseEngine: () -> Unit,
    ): String = suspendCancellableCoroutine { cont ->
        val finished = AtomicBoolean(false)
        fun finish(outcome: Result<String>) {
            if (!finished.compareAndSet(false, true)) return
            try {
                if (cont.isActive) cont.resumeWith(outcome)
            } finally {
                releaseEngine()
            }
        }

        if (!cont.isActive) {
            finish(Result.failure(IllegalStateException("worker_dispatch_cancelled")))
        } else {
            try {
                invoke(object : MethodChannel.Result {
                    override fun success(result: Any?) = finish(
                        if (result is String) Result.success(result)
                        else Result.failure(IllegalStateException("dart_outcome_invalid")),
                    )

                    override fun error(code: String, message: String?, details: Any?) =
                        finish(Result.failure(IllegalStateException("dart_outcome_error")))

                    override fun notImplemented() =
                        finish(Result.failure(IllegalStateException("dart_outcome_unavailable")))
                })
            } catch (error: Throwable) {
                finish(Result.failure(error))
            }
        }
        // No cancellation release: Dart still owns the engine until its reply.
    }
}
