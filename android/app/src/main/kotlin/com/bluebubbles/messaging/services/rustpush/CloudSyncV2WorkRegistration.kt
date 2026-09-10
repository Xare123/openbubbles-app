package com.bluebubbles.messaging.services.rustpush

import android.content.Context

internal data class CloudSyncV2WorkRegistrationSnapshot(
    val scopeHash: String,
)

/**
 * Durable, content-free authorization for the read-only Canary worker.
 *
 * The preference contains only a SHA-256 of the complete semantic CloudKit
 * scope. Alpha, Beta, and production package names cannot configure or use it.
 */
internal object CloudSyncV2WorkRegistration {
    const val CANARY_PACKAGE = "com.bluebubbles.messaging.cloudkitcanary"
    private const val PREFS_NAME = "cloud_sync_v2_background"
    private const val PREF_SCOPE_HASH = "scope_hash"
    private val scopeHashPattern = Regex("^[a-f0-9]{64}$")

    fun isCanonicalScopeHash(value: String?): Boolean =
        value != null && scopeHashPattern.matches(value)

    fun current(context: Context): CloudSyncV2WorkRegistrationSnapshot? {
        if (context.packageName != CANARY_PACKAGE) return null
        val scopeHash = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(PREF_SCOPE_HASH, null)
        if (!isCanonicalScopeHash(scopeHash)) return null
        return CloudSyncV2WorkRegistrationSnapshot(scopeHash!!)
    }

    fun configure(context: Context, scopeHash: String): Boolean {
        if (context.packageName != CANARY_PACKAGE || !isCanonicalScopeHash(scopeHash)) {
            return false
        }
        val appContext = context.applicationContext
        val previous = current(appContext)?.scopeHash
        val committed = appContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PREF_SCOPE_HASH, scopeHash)
            .commit()
        if (!committed) return false
        if (previous != null && previous != scopeHash) {
            CloudSyncV2WorkScheduler.cancelScopeHash(appContext, previous)
        }
        return CloudSyncV2WorkScheduler.enqueueScopeHash(
            appContext,
            scopeHash,
            CloudSyncV2WorkKind.METADATA,
        )
    }

    fun enqueue(context: Context, kind: CloudSyncV2WorkKind): Boolean {
        if (kind != CloudSyncV2WorkKind.METADATA) return false
        val appContext = context.applicationContext
        val registration = current(appContext) ?: return false
        return CloudSyncV2WorkScheduler.enqueueScopeHash(
            appContext,
            registration.scopeHash,
            kind,
        )
    }

    fun disable(context: Context): Boolean {
        if (context.packageName != CANARY_PACKAGE) return false
        val appContext = context.applicationContext
        val previous = current(appContext)?.scopeHash
        val committed = appContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(PREF_SCOPE_HASH)
            .commit()
        if (previous != null) {
            CloudSyncV2WorkScheduler.cancelScopeHash(appContext, previous)
        }
        return committed
    }

    fun matches(context: Context, scopeHash: String): Boolean =
        current(context)?.scopeHash == scopeHash
}
