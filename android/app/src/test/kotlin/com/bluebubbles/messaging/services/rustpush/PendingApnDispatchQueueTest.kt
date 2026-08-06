package com.bluebubbles.messaging.services.rustpush

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingApnDispatchQueueTest {
    @Test
    fun `coalesces retries without changing dispatch order`() {
        val queue = PendingApnDispatchQueue(capacity = 4)

        queue.enqueue(pointer = 10UL, retry = 0UL)
        queue.enqueue(pointer = 20UL, retry = 0UL)
        val duplicate = queue.enqueue(pointer = 10UL, retry = 2UL)

        assertFalse(duplicate.added)
        assertFalse(duplicate.evicted)
        assertEquals(2, duplicate.size)
        assertEquals(
            listOf(
                PendingApnDispatch(pointer = 10UL, retry = 2UL),
                PendingApnDispatch(pointer = 20UL, retry = 0UL),
            ),
            queue.drain(),
        )
    }

    @Test
    fun `evicts only the oldest Android dispatch when capacity is reached`() {
        val queue = PendingApnDispatchQueue(capacity = 2)

        queue.enqueue(pointer = 10UL, retry = 0UL)
        queue.enqueue(pointer = 20UL, retry = 0UL)
        val overflow = queue.enqueue(pointer = 30UL, retry = 1UL)

        assertTrue(overflow.added)
        assertTrue(overflow.evicted)
        assertEquals(2, overflow.size)
        assertEquals(
            listOf(
                PendingApnDispatch(pointer = 20UL, retry = 0UL),
                PendingApnDispatch(pointer = 30UL, retry = 1UL),
            ),
            queue.drain(),
        )
    }

    @Test
    fun `drain is deterministic and empties the buffer`() {
        val queue = PendingApnDispatchQueue(capacity = 3)

        queue.enqueue(pointer = 1UL, retry = 0UL)
        queue.enqueue(pointer = 2UL, retry = 1UL)

        assertEquals(listOf(1UL, 2UL), queue.drain().map { it.pointer })
        assertTrue(queue.drain().isEmpty())
        assertEquals(0, queue.clear())
    }

    @Test
    fun `headless handoff removes stale pointer before a later retry`() {
        val queue = PendingApnDispatchQueue(capacity = 3)

        queue.enqueue(pointer = 7UL, retry = 0UL)
        val handedOff = queue.drain()
        queue.enqueue(pointer = 7UL, retry = 1UL)

        assertEquals(
            listOf(PendingApnDispatch(pointer = 7UL, retry = 0UL)),
            handedOff,
        )
        assertEquals(
            listOf(PendingApnDispatch(pointer = 7UL, retry = 1UL)),
            queue.drain(),
        )
    }
}
