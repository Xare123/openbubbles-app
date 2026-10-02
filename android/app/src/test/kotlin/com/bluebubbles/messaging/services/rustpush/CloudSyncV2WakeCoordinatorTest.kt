package com.bluebubbles.messaging.services.rustpush

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class CloudSyncV2WakeCoordinatorTest {
    private class Store : CloudSyncV2WakeStore {
        var record = CloudSyncV2WakeRecord()
        var accepts = true
        override fun read() = record
        override fun commit(record: CloudSyncV2WakeRecord): Boolean {
            if (!accepts) return false
            this.record = record
            return true
        }
    }

    private class Backend : CloudSyncV2WakeBackend {
        val states = mutableMapOf<UUID, Boolean>()
        val enqueues = mutableListOf<UUID>()
        val cancels = mutableListOf<UUID>()
        var enqueueGate: CompletableDeferred<Unit>? = null
        var failEnqueue = false
        var failCancel = false
        var finishBeforeEnqueue: UUID? = null
        override suspend fun unfinished(workId: UUID) = states[workId]
        override suspend fun enqueue(record: CloudSyncV2WakeRecord) {
            val id = requireNotNull(record.workId)
            enqueues += id
            enqueueGate?.await()
            if (failEnqueue) error("enqueue Operation failed")
            if (finishBeforeEnqueue == id) {
                finishBeforeEnqueue = null
                states[id] = false
            }
            if (states[id] == false) error("terminal WorkSpec ID cannot be inserted again")
            states[id] = true // KEEP coalesces the same unfinished request.
        }
        override suspend fun cancel(workId: UUID) {
            cancels += workId
            if (failCancel) error("cancel Operation failed")
            states[workId] = false
        }
    }

    private class Fixture {
        val store = Store()
        val backend = Backend()
        private var sequence = 0L
        fun coordinator() = CloudSyncV2WakeCoordinator(
            store, backend, { UUID(0, ++sequence) }, Dispatchers.Unconfined,
        )
        val coordinator = coordinator()
        val scope = "a".repeat(64)
        val otherScope = "b".repeat(64)
        val registration get() = requireNotNull(store.record.registration)
        val id get() = requireNotNull(store.record.workId)
    }

    @Test fun `configure waits for durable commit and enqueue completion`() = runBlocking {
        val f = Fixture()
        val gate = CompletableDeferred<Unit>()
        f.backend.enqueueGate = gate
        val configured = async(start = CoroutineStart.UNDISPATCHED) {
            f.coordinator.configure(f.scope)
        }
        assertFalse(configured.isCompleted)
        assertNotNull(f.store.record.workId)
        assertTrue(f.backend.states.isEmpty())
        gate.complete(Unit)
        assertTrue(configured.await())
        assertEquals(1, f.backend.states.size)
    }

    @Test fun `failed preference commit schedules and cancels nothing`() = runBlocking {
        val f = Fixture()
        f.store.accepts = false
        assertFalse(f.coordinator.configure(f.scope))
        assertEquals(CloudSyncV2WakeRecord(), f.store.record)
        assertTrue(f.backend.enqueues.isEmpty())
        assertTrue(f.backend.cancels.isEmpty())
    }

    @Test fun `thousand queued hints coalesce into the same reservation`() = runBlocking {
        val f = Fixture()
        assertTrue(f.coordinator.configure(f.scope))
        val original = f.id
        repeat(1_000) { assertTrue(f.coordinator.hint(f.registration)) }
        assertEquals(original, f.id)
        assertEquals(1_001L, f.store.record.generation)
        assertEquals(setOf(original), f.backend.states.keys)
        val attempt = requireNotNull(f.coordinator.begin(f.registration, original))
        assertEquals(1_001L, attempt.observedGeneration)
        assertTrue(f.coordinator.seal(attempt))
        assertNull(f.store.record.workId)
    }

    @Test fun `thousand hints during handoff reserve exactly one follow up`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        val attempt = requireNotNull(f.coordinator.begin(f.registration, original))
        repeat(1_000) { assertTrue(f.coordinator.hint(f.registration)) }
        assertEquals(original, f.id)
        assertTrue(f.coordinator.seal(attempt))
        val followUp = f.id
        assertNotEquals(original, followUp)
        assertEquals(setOf(original, followUp), f.backend.states.keys)
        assertTrue(f.backend.cancels.isEmpty())
        assertTrue(f.coordinator.hint(f.registration))
        assertEquals(followUp, f.id)
        assertEquals(2, f.backend.states.size)
    }

    @Test fun `hint after seal before predecessor terminal commit uses new request`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        val attempt = requireNotNull(f.coordinator.begin(f.registration, original))
        assertTrue(f.coordinator.seal(attempt))
        assertEquals(true, f.backend.states[original]) // Still RUNNING in WorkManager.
        assertNull(f.store.record.workId)
        assertTrue(f.coordinator.hint(f.registration))
        assertNotEquals(original, f.id)
        assertEquals(2, f.backend.states.size)
        assertNull(f.coordinator.begin(f.registration, original))
    }

    @Test fun `terminal predecessor cannot poison independently queued follow up`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        val attempt = requireNotNull(f.coordinator.begin(f.registration, original))
        f.coordinator.hint(f.registration)
        assertTrue(f.coordinator.seal(attempt))
        val next = f.id
        f.backend.states[original] = false // Failed or cancelled predecessor.
        assertEquals(true, f.backend.states[next])
        assertNotNull(f.coordinator.begin(f.registration, next))
    }

    @Test fun `new hint after terminal unsealed request does not reuse its ID`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        f.backend.states[original] = false
        assertTrue(f.coordinator.hint(f.registration))
        assertNotEquals(original, f.id)
        assertEquals(true, f.backend.states[f.id])
    }

    @Test fun `terminal transition racing status lookup is repaired before acknowledgement`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        f.backend.finishBeforeEnqueue = original
        assertTrue(f.coordinator.hint(f.registration))
        assertNotEquals(original, f.id)
        assertEquals(2L, f.store.record.generation)
        assertEquals(true, f.backend.states[f.id])
    }

    @Test fun `recreated coordinator recovers committed but absent reservation with same ID`() = runBlocking {
        val f = Fixture()
        f.backend.failEnqueue = true
        try { f.coordinator.configure(f.scope); fail("expected enqueue failure") }
        catch (_: IllegalStateException) { }
        val reserved = f.id
        assertTrue(f.backend.states.isEmpty())
        f.backend.failEnqueue = false
        assertTrue(f.coordinator().hint(f.registration))
        assertEquals(reserved, f.id)
        assertEquals(setOf(reserved), f.backend.states.keys)
    }

    @Test fun `recreated coordinator preserves known request and registration epoch`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        val epoch = f.registration.epoch
        assertTrue(f.coordinator().configure(f.scope))
        assertEquals(epoch, f.registration.epoch)
        assertEquals(original, f.id)
        assertEquals(1, f.backend.states.size)
    }

    @Test fun `older retry repairs absent sealed follow up without repeating its read`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        val attempt = requireNotNull(f.coordinator.begin(f.registration, original))
        f.coordinator.hint(f.registration)
        f.backend.failEnqueue = true
        try { f.coordinator.seal(attempt); fail("expected enqueue failure") }
        catch (_: IllegalStateException) { }
        val next = f.id
        assertNotEquals(original, next)
        assertNull(f.backend.states[next])
        f.backend.failEnqueue = false
        assertNull(f.coordinator().begin(f.registration, original))
        assertEquals(next, f.id)
        assertEquals(true, f.backend.states[next])
    }

    @Test fun `captured A hint cannot be adopted after A B A registration changes`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val oldA = f.registration
        f.coordinator.configure(f.otherScope)
        f.coordinator.configure(f.scope)
        assertNotEquals(oldA.epoch, f.registration.epoch)
        val current = f.store.record
        assertFalse(f.coordinator.hint(oldA))
        assertEquals(current, f.store.record)
    }

    @Test fun `disable advances epoch and cancels only its revoked request`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val old = f.registration
        val original = f.id
        assertTrue(f.coordinator.disable())
        assertNull(f.store.record.registration)
        assertEquals(old.epoch + 1, f.store.record.epoch)
        assertEquals(listOf(original), f.backend.cancels)
        assertFalse(f.coordinator.hint(old))
        f.coordinator.configure(f.scope)
        assertTrue(f.registration.epoch > old.epoch)
        assertNotNull(f.coordinator.begin(f.registration, f.id))
    }

    @Test fun `failed disable commit leaves registration and existing request intact`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val before = f.store.record
        f.store.accepts = false
        assertFalse(f.coordinator.disable())
        assertEquals(before, f.store.record)
        assertTrue(f.backend.cancels.isEmpty())
    }

    @Test fun `failed cancellation still leaves previous epoch revoked`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val before = f.registration
        f.backend.failCancel = true
        try { f.coordinator.disable(); fail("expected cancel failure") }
        catch (_: IllegalStateException) { }
        assertNull(f.store.record.registration)
        assertFalse(f.coordinator.hint(before))
    }

    @Test fun `late old completion cannot seal or cancel newer account work`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        val attempt = requireNotNull(f.coordinator.begin(f.registration, original))
        f.coordinator.configure(f.otherScope)
        val current = f.store.record
        val cancellationCount = f.backend.cancels.size
        assertTrue(f.coordinator.seal(attempt))
        assertEquals(current, f.store.record)
        assertEquals(cancellationCount, f.backend.cancels.size)
        assertEquals(listOf(original), f.backend.cancels)
    }

    @Test fun `failed seal commit retains hints for the next bounded retry`() = runBlocking {
        val f = Fixture()
        f.coordinator.configure(f.scope)
        val original = f.id
        val attempt = requireNotNull(f.coordinator.begin(f.registration, original))
        f.coordinator.hint(f.registration)
        val before = f.store.record
        f.store.accepts = false
        assertFalse(f.coordinator.seal(attempt))
        assertEquals(before, f.store.record)
        assertEquals(1, f.backend.states.size)
        f.store.accepts = true
        val retried = requireNotNull(f.coordinator.begin(f.registration, original))
        assertTrue(retried.observedGeneration > attempt.observedGeneration)
        assertTrue(f.coordinator.seal(retried))
        assertNull(f.store.record.workId)
    }

    @Test fun `invalid hashes and exhausted counters fail closed without scheduling`() = runBlocking {
        val f = Fixture()
        assertFalse(f.coordinator.configure("A".repeat(64)))
        assertTrue(f.backend.states.isEmpty())
        f.store.record = CloudSyncV2WakeRecord(epoch = Long.MAX_VALUE)
        try { f.coordinator.configure(f.scope); fail("expected epoch exhaustion") }
        catch (_: IllegalStateException) { }
        assertTrue(f.backend.states.isEmpty())
    }
}
