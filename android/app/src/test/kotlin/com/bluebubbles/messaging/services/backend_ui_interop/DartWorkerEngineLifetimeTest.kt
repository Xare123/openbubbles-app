package com.bluebubbles.messaging.services.backend_ui_interop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DartWorkerEngineLifetimeTest {
    private val first = Any()
    private var current: Any? = first
    private val idleChecks = mutableListOf<() -> Unit>()
    private val destroyed = mutableListOf<Any>()
    private val lifetime = DartWorkerEngineLifetime(
        currentWorker = { current },
        scheduleIdleCheck = { idleChecks.add(it) },
        destroyWorker = { destroyed.add(it); current = null },
    )

    @Test
    fun `worker remains alive until its last actual Dart reply`() {
        val firstReply = lifetime.acquire(first)
        val secondReply = lifetime.acquire(first)
        firstReply()
        assertTrue(idleChecks.isEmpty())
        secondReply()
        assertEquals(1, idleChecks.size)
        idleChecks.single()()
        assertEquals(listOf(first), destroyed)
    }

    @Test
    fun `duplicate reply cannot underflow active work`() {
        val firstReply = lifetime.acquire(first)
        val secondReply = lifetime.acquire(first)
        repeat(3) { firstReply() }
        assertTrue(idleChecks.isEmpty())
        secondReply()
        idleChecks.single()()
        assertEquals(listOf(first), destroyed)
    }

    @Test
    fun `new work invalidates an already posted idle disposal`() {
        lifetime.acquire(first)()
        val nextReply = lifetime.acquire(first)
        idleChecks[0]()
        assertTrue(destroyed.isEmpty())
        nextReply()
        idleChecks[1]()
        assertEquals(listOf(first), destroyed)
    }

    @Test
    fun `newly completed work receives its own full idle grace period`() {
        lifetime.acquire(first)()
        lifetime.acquire(first)()
        idleChecks[0]()
        assertTrue(destroyed.isEmpty())
        idleChecks[1]()
        assertEquals(listOf(first), destroyed)
    }

    @Test
    fun `late callback cannot destroy a replacement worker`() {
        lifetime.acquire(first)()
        val replacement = Any()
        current = replacement
        val reply = lifetime.acquire(replacement)
        idleChecks[0]()
        assertTrue(destroyed.isEmpty())
        reply()
        idleChecks[1]()
        assertEquals(listOf(replacement), destroyed)
    }

    @Test
    fun `UI engine replies never schedule worker destruction`() {
        lifetime.acquire(Any())()
        assertTrue(idleChecks.isEmpty())
        assertEquals(first, current)
    }
}
