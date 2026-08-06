package com.bluebubbles.messaging.services.rustpush

internal data class PendingApnDispatch(
    val pointer: ULong,
    val retry: ULong,
)

internal data class PendingApnEnqueueResult(
    val added: Boolean,
    val evicted: Boolean,
    val size: Int,
)

/**
 * A short-lived Android-side dispatch buffer for APNs pointers received while
 * the main Flutter engine exists but has not registered its method channel yet.
 *
 * Rust remains the source of truth for retrying and dropping each pointer.
 * Removing an entry here never acknowledges or removes it from the Rust queue.
 */
internal class PendingApnDispatchQueue(
    private val capacity: Int,
) {
    private val pending = LinkedHashMap<ULong, PendingApnDispatch>()

    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    @Synchronized
    fun enqueue(pointer: ULong, retry: ULong): PendingApnEnqueueResult {
        val existing = pending[pointer]
        if (existing != null) {
            if (retry > existing.retry) {
                pending[pointer] = existing.copy(retry = retry)
            }
            return PendingApnEnqueueResult(
                added = false,
                evicted = false,
                size = pending.size,
            )
        }

        var evicted = false
        if (pending.size >= capacity) {
            val oldest = pending.entries.iterator()
            if (oldest.hasNext()) {
                oldest.next()
                oldest.remove()
                evicted = true
            }
        }

        pending[pointer] = PendingApnDispatch(pointer, retry)
        return PendingApnEnqueueResult(
            added = true,
            evicted = evicted,
            size = pending.size,
        )
    }

    @Synchronized
    fun drain(): List<PendingApnDispatch> {
        val result = pending.values.toList()
        pending.clear()
        return result
    }

    @Synchronized
    fun clear(): Int {
        val size = pending.size
        pending.clear()
        return size
    }
}
