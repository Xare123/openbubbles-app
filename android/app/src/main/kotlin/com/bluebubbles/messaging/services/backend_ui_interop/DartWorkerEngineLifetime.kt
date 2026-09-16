package com.bluebubbles.messaging.services.backend_ui_interop

import java.util.IdentityHashMap

/** Engine leases and delayed disposal are serialized on the Android main thread. */
internal class DartWorkerEngineLifetime<E : Any>(
    private val currentWorker: () -> E?,
    private val scheduleIdleCheck: (() -> Unit) -> Unit,
    private val destroyWorker: (E) -> Unit,
) {
    private val active = IdentityHashMap<E, Int>()
    private val pendingIdle = IdentityHashMap<E, Any>()
    private val retiring = IdentityHashMap<E, (() -> Unit)?>()

    /** Stop new calls to a detached UI engine, then await its actual Dart replies. */
    fun retireWhenIdle(engine: E, ready: () -> Unit) {
        if (retiring.containsKey(engine)) return
        check(currentWorker() !== engine) { "worker_retirement_requires_worker_owner" }
        pendingIdle.remove(engine)
        retiring[engine] = ready
        notifyRetiredIfIdle(engine)
    }

    /** Drop only the exact retired instance after native destruction succeeds. */
    fun forgetRetired(engine: E) {
        check(!active.containsKey(engine)) { "engine_still_has_pending_calls" }
        retiring.remove(engine)
    }

    private fun notifyRetiredIfIdle(engine: E) {
        if (active.containsKey(engine)) return
        val ready = retiring[engine] ?: return
        retiring[engine] = null
        ready()
    }

    /** Release only when Dart replies (or dispatch fails), not when its waiter cancels. */
    fun acquire(engine: E): () -> Unit {
        check(!retiring.containsKey(engine)) { "engine_retiring" }
        pendingIdle.remove(engine)
        active[engine] = (active[engine] ?: 0) + 1
        var released = false
        return release@{
            if (released) return@release
            released = true
            val remaining = active.getValue(engine) - 1
            if (remaining > 0) {
                active[engine] = remaining
            } else {
                active.remove(engine)
                notifyRetiredIfIdle(engine)
                if (currentWorker() === engine) {
                    val idleGeneration = Any()
                    pendingIdle[engine] = idleGeneration
                    scheduleIdleCheck {
                        // Recheck at disposal, not before posting to the main thread.
                        // A late reply must never dispose a replacement or UI engine.
                        if (pendingIdle[engine] !== idleGeneration) return@scheduleIdleCheck
                        pendingIdle.remove(engine)
                        if (currentWorker() === engine && !active.containsKey(engine)) {
                            destroyWorker(engine)
                        }
                    }
                }
            }
        }
    }
}
