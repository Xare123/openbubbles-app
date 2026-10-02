package com.bluebubbles.messaging.services.rustpush

import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

internal data class CloudSyncV2WorkRegistrationSnapshot(val scopeHash: String, val epoch: Long)

/** One durable reservation. It contains no account identifier or message data. */
internal data class CloudSyncV2WakeRecord(
    val epoch: Long = 0,
    val scopeHash: String? = null,
    val generation: Long = 0,
    val workId: UUID? = null,
) {
    init {
        require(epoch >= 0)
        require(if (scopeHash == null) generation == 0L && workId == null
            else isCanonicalScopeHash(scopeHash) && epoch > 0 && generation > 0)
    }

    val registration: CloudSyncV2WorkRegistrationSnapshot?
        get() = scopeHash?.let { CloudSyncV2WorkRegistrationSnapshot(it, epoch) }

    companion object {
        private val scopeHashPattern = Regex("^[a-f0-9]{64}$")
        fun isCanonicalScopeHash(value: String?): Boolean =
            value != null && scopeHashPattern.matches(value)
    }
}

internal data class CloudSyncV2WakeAttempt(
    val registration: CloudSyncV2WorkRegistrationSnapshot,
    val workId: UUID,
    val observedGeneration: Long,
)

internal interface CloudSyncV2WakeStore {
    fun read(): CloudSyncV2WakeRecord
    fun commit(record: CloudSyncV2WakeRecord): Boolean
}

internal interface CloudSyncV2WakeBackend {
    /** null means absent; false means terminal. Uses public WorkInfo only. */
    suspend fun unfinished(workId: UUID): Boolean?
    /** Returns only after WorkManager's enqueue Operation succeeds. */
    suspend fun enqueue(record: CloudSyncV2WakeRecord)
    suspend fun cancel(workId: UUID)
}

/**
 * Serializes admission and the worker's terminal seal, not CloudKit reads.
 * A hint during a read advances a durable counter. The seal reserves at most
 * one independent follow-up, so a failed predecessor cannot poison a chain.
 * After the seal, later hints cannot be swallowed by the predecessor's KEEP.
 */
internal class CloudSyncV2WakeCoordinator(
    private val store: CloudSyncV2WakeStore,
    private val backend: CloudSyncV2WakeBackend,
    private val newId: () -> UUID = UUID::randomUUID,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()

    private suspend fun <T> serialized(block: suspend () -> T): T = mutex.withLock {
        // Acquire the mutex before changing dispatchers, preserving admission
        // order for the main-thread channel and worker callers. No disk I/O or
        // blocking Future.get runs on that thread.
        withContext(dispatcher) { withTimeout(30_000L) { block() } }
    }

    private fun increment(value: Long): Long {
        check(value < Long.MAX_VALUE) { "Cloud Sync V2 wake counter exhausted" }
        return value + 1
    }

    private suspend fun reserve(record: CloudSyncV2WakeRecord): CloudSyncV2WakeRecord {
        val id = record.workId
        // Recreate an absent reservation with its SAME ID after a crash between
        // preference commit and enqueue. A terminal ID must never be reused.
        return if (id == null || backend.unfinished(id) == false) {
            record.copy(workId = newId())
        } else record
    }

    private suspend fun submit(record: CloudSyncV2WakeRecord): Boolean {
        try {
            backend.enqueue(record)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            // An early worker failure can race the public status query. A
            // terminal WorkSpec ID cannot be inserted again. Repair exactly that
            // observed terminal case, not an unknown enqueue outcome.
            if (backend.unfinished(requireNotNull(record.workId)) != false) throw error
            val replacement = record.copy(workId = newId())
            if (!store.commit(replacement)) return false
            backend.enqueue(replacement)
        }
        return true
    }

    suspend fun configure(scopeHash: String): Boolean = serialized {
        if (!CloudSyncV2WakeRecord.isCanonicalScopeHash(scopeHash)) return@serialized false
        val previous = store.read()
        val sameRegistration = previous.scopeHash == scopeHash
        val requested = if (sameRegistration) {
            previous.copy(generation = increment(previous.generation))
        } else {
            CloudSyncV2WakeRecord(increment(previous.epoch), scopeHash, 1)
        }
        val reserved = reserve(requested)
        if (!store.commit(reserved)) return@serialized false
        // Revoke the old epoch before cancellation, and cancel only its exact
        // request. A delayed cancellation cannot affect a newer registration.
        if (!sameRegistration) previous.workId?.let { backend.cancel(it) }
        submit(reserved)
    }

    suspend fun hint(expected: CloudSyncV2WorkRegistrationSnapshot): Boolean = serialized {
        val current = store.read()
        if (current.registration != expected) return@serialized false
        val reserved = reserve(current.copy(generation = increment(current.generation)))
        if (!store.commit(reserved)) return@serialized false
        submit(reserved)
    }

    suspend fun disable(): Boolean = serialized {
        val previous = store.read()
        if (!store.commit(CloudSyncV2WakeRecord(epoch = increment(previous.epoch)))) {
            return@serialized false
        }
        previous.workId?.let { backend.cancel(it) }
        true
    }

    suspend fun begin(
        expected: CloudSyncV2WorkRegistrationSnapshot,
        workId: UUID,
    ): CloudSyncV2WakeAttempt? = serialized {
        val current = store.read()
        if (current.registration != expected) return@serialized null
        if (current.workId != workId) {
            // An older retry can repair a follow-up reserved before a process
            // died or enqueue failed. It must not dispatch the older read again.
            current.workId?.let {
                if (backend.unfinished(it) == null && !submit(current)) {
                    error("Cloud Sync V2 wake repair commit failed")
                }
            }
            return@serialized null
        }
        CloudSyncV2WakeAttempt(expected, workId, current.generation)
    }

    suspend fun seal(attempt: CloudSyncV2WakeAttempt): Boolean = serialized {
        val current = store.read()
        if (current.registration != attempt.registration || current.workId != attempt.workId) {
            return@serialized true // Stale completion may not touch newer work.
        }
        check(current.generation >= attempt.observedGeneration)
        val followUp = current.generation > attempt.observedGeneration
        val sealed = current.copy(workId = if (followUp) newId() else null)
        if (!store.commit(sealed)) return@serialized false
        // The Dart handoff is already finished. Seal before WorkManager commits
        // its terminal result; a hint in that window owns a different ID/name.
        if (followUp) submit(sealed) else true
    }
}
