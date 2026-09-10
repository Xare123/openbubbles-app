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

    /** Release only when Dart replies (or dispatch fails), not when its waiter cancels. */
    fun acquire(engine: E): () -> Unit {
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
