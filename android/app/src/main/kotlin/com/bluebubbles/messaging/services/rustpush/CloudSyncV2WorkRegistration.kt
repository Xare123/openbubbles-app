package com.bluebubbles.messaging.services.rustpush

import android.content.Context
import android.content.pm.ApplicationInfo
import java.util.UUID

/**
 * Durable, content-free authorization for the read-only test worker.
 *
 * Only the scope hash, monotonic counters and opaque WorkRequest ID persist.
 * Alpha, Beta, and production package names cannot configure or use it.
 */
internal object CloudSyncV2WorkRegistration {
    const val CANARY_PACKAGE = "com.bluebubbles.messaging.cloudkitcanary"
    const val BACKEND_AGENT_PACKAGE = "com.bluebubbles.messaging.backendtest"
    private const val PREFS_NAME = "cloud_sync_v2_background"
    private const val PREF_SCOPE_HASH = "scope_hash"
    private const val PREF_EPOCH = "registration_epoch"
    private const val PREF_GENERATION = "requested_generation"
    private const val PREF_WORK_ID = "active_work_id"
    @Volatile private var wakeCoordinator: CloudSyncV2WakeCoordinator? = null

    // Preserve Canary admission. The separate backend app must be installed as
    // debuggable; neither a caller-supplied argument nor its package name proves it.
    internal fun isAllowedPackage(packageName: String, applicationFlags: Int): Boolean =
        packageName == CANARY_PACKAGE ||
            (packageName == BACKEND_AGENT_PACKAGE &&
                applicationFlags and ApplicationInfo.FLAG_DEBUGGABLE != 0)

    fun isAllowed(context: Context): Boolean =
        if (context.packageName == CANARY_PACKAGE) true
        else context.packageName == BACKEND_AGENT_PACKAGE && runCatching {
            isAllowedPackage(context.packageName, context.applicationInfo.flags)
        }.getOrDefault(false)

    fun isCanonicalScopeHash(value: String?): Boolean =
        CloudSyncV2WakeRecord.isCanonicalScopeHash(value)

    fun current(context: Context): CloudSyncV2WorkRegistrationSnapshot? {
        if (!isAllowed(context)) return null
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val scopeHash = prefs.getString(PREF_SCOPE_HASH, null)
        val epoch = prefs.getLong(PREF_EPOCH, 0)
        if (!isCanonicalScopeHash(scopeHash) || epoch <= 0) return null
        return CloudSyncV2WorkRegistrationSnapshot(scopeHash!!, epoch)
    }

    private fun coordinator(context: Context): CloudSyncV2WakeCoordinator = synchronized(this) {
        wakeCoordinator ?: CloudSyncV2WakeCoordinator(
            store = object : CloudSyncV2WakeStore {
                private val prefs = context.applicationContext
                    .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

                override fun read(): CloudSyncV2WakeRecord {
                    val epoch = prefs.getLong(PREF_EPOCH, 0)
                    check(epoch >= 0)
                    val scopeHash = prefs.getString(PREF_SCOPE_HASH, null)
                    val generation = prefs.getLong(PREF_GENERATION, 0)
                    // An installed legacy hash has no epoch/reservation. It is
                    // not authorized until normal configuration commits V2 state.
                    if (!isCanonicalScopeHash(scopeHash) || epoch == 0L || generation <= 0) {
                        return CloudSyncV2WakeRecord(epoch = epoch)
                    }
                    val workId = prefs.getString(PREF_WORK_ID, null)?.let(UUID::fromString)
                    return CloudSyncV2WakeRecord(epoch, scopeHash, generation, workId)
                }

                override fun commit(record: CloudSyncV2WakeRecord): Boolean {
                    val editor = prefs.edit().putLong(PREF_EPOCH, record.epoch)
                    if (record.scopeHash == null) {
                        editor.remove(PREF_SCOPE_HASH).remove(PREF_GENERATION).remove(PREF_WORK_ID)
                    } else {
                        editor.putString(PREF_SCOPE_HASH, record.scopeHash)
                            .putLong(PREF_GENERATION, record.generation)
                        if (record.workId == null) editor.remove(PREF_WORK_ID)
                        else editor.putString(PREF_WORK_ID, record.workId.toString())
                    }
                    return editor.commit()
                }
            },
            backend = object : CloudSyncV2WakeBackend {
                override suspend fun unfinished(workId: UUID): Boolean? =
                    CloudSyncV2WorkScheduler.unfinished(context, workId)
                override suspend fun enqueue(record: CloudSyncV2WakeRecord) =
                    CloudSyncV2WorkScheduler.enqueue(context, record)
                override suspend fun cancel(workId: UUID) =
                    CloudSyncV2WorkScheduler.cancel(context, workId)
            },
        ).also { wakeCoordinator = it }
    }

    suspend fun configure(context: Context, scopeHash: String): Boolean {
        if (!isAllowed(context) || !isCanonicalScopeHash(scopeHash)) {
            return false
        }
        return coordinator(context.applicationContext).configure(scopeHash)
    }

    suspend fun enqueue(
        context: Context,
        kind: CloudSyncV2WorkKind,
        expected: CloudSyncV2WorkRegistrationSnapshot,
    ): Boolean {
        if (!isAllowed(context) || kind != CloudSyncV2WorkKind.METADATA) return false
        return coordinator(context.applicationContext).hint(expected)
    }

    suspend fun disable(context: Context): Boolean {
        if (!isAllowed(context)) return false
        return coordinator(context.applicationContext).disable()
    }

    fun matches(context: Context, expected: CloudSyncV2WorkRegistrationSnapshot): Boolean =
        current(context) == expected

    suspend fun begin(context: Context, expected: CloudSyncV2WorkRegistrationSnapshot, workId: UUID):
        CloudSyncV2WakeAttempt? = if (isAllowed(context)) {
            coordinator(context.applicationContext).begin(expected, workId)
        } else null

    suspend fun seal(context: Context, attempt: CloudSyncV2WakeAttempt): Boolean =
        isAllowed(context) && coordinator(context.applicationContext).seal(attempt)
}
