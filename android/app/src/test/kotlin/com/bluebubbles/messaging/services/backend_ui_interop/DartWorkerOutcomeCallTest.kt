package com.bluebubbles.messaging.services.backend_ui_interop

import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DartWorkerOutcomeCallTest {
    @Test
    fun `cancelled waiter keeps the actual Dart operation leased until reply`() = runBlocking {
        val engine = Any()
        var worker: Any? = engine
        val idleChecks = mutableListOf<() -> Unit>()
        val lifetime = DartWorkerEngineLifetime(
            currentWorker = { worker },
            scheduleIdleCheck = { idleChecks.add(it) },
            destroyWorker = { worker = null },
        )
        lateinit var reply: MethodChannel.Result
        val waiting = async(start = CoroutineStart.UNDISPATCHED) {
            DartWorkerOutcomeCall.awaitOutcome({ reply = it }, lifetime.acquire(engine))
        }
        waiting.cancelAndJoin()
        assertTrue(idleChecks.isEmpty())
        assertEquals(engine, worker)
        reply.success("complete")
        reply.success("complete")
        assertEquals(1, idleChecks.size)
        idleChecks.single()()
        assertEquals(null, worker)
    }

    @Test
    fun `success passes through a disposition and releases exactly once`() = runBlocking {
        var releases = 0
        val outcome = DartWorkerOutcomeCall.awaitOutcome(
            invoke = { it.success("retry"); it.notImplemented() },
            releaseEngine = { releases++ },
        )
        assertEquals("retry", outcome)
        assertEquals(1, releases)
    }

    @Test
    fun `invalid reply releases its lease and cannot be success`() = runBlocking {
        var releases = 0
        val failure = runCatching {
            DartWorkerOutcomeCall.awaitOutcome({ it.success(null) }, { releases++ })
        }.exceptionOrNull()
        assertEquals("dart_outcome_invalid", failure?.message)
        assertEquals(1, releases)
    }

    @Test
    fun `Dart error is content free and releases its lease`() = runBlocking {
        var releases = 0
        val failure = runCatching {
            DartWorkerOutcomeCall.awaitOutcome(
                { it.error("private-code", "private-message", "private-details") },
                { releases++ },
            )
        }.exceptionOrNull()
        assertEquals("dart_outcome_error", failure?.message)
        assertEquals(1, releases)
    }

    @Test
    fun `unimplemented method terminates without leaking the engine lease`() = runBlocking {
        var releases = 0
        val failure = runCatching {
            DartWorkerOutcomeCall.awaitOutcome({ it.notImplemented() }, { releases++ })
        }.exceptionOrNull()
        assertEquals("dart_outcome_unavailable", failure?.message)
        assertEquals(1, releases)
    }

    @Test
    fun `synchronous dispatch exception releases even without a Dart callback`() = runBlocking {
        var releases = 0
        val failure = runCatching {
            DartWorkerOutcomeCall.awaitOutcome({ error("test-dispatch-failure") }, { releases++ })
        }.exceptionOrNull()
        assertEquals("test-dispatch-failure", failure?.message)
        assertEquals(1, releases)
    }
}
