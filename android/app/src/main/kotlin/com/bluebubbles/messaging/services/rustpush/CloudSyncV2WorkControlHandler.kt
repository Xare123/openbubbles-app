package com.bluebubbles.messaging.services.rustpush

import android.content.Context
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Dart-to-Android control surface. It accepts no account or message data. */
class CloudSyncV2WorkControlHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "cloud-sync-v2-background-control"
        private val controlScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context,
    ) {
        if (context.packageName != CloudSyncV2WorkRegistration.CANARY_PACKAGE) {
            result.success(false)
            return
        }
        val action = call.argument<String>("action")
        val scopeHash = call.argument<String>("scopeHash")
        val kind = runCatching {
            CloudSyncV2WorkKind.valueOf(call.argument<String>("kind") ?: "")
        }.getOrNull()
        // Capture the current epoch at admission. If configuration changes
        // while this hint waits, even A -> B -> A cannot adopt the old hint.
        val expected = if (action == "hint") {
            runCatching { CloudSyncV2WorkRegistration.current(context) }.getOrNull()
        } else null
        if (action == "hint" && (kind != CloudSyncV2WorkKind.METADATA ||
                !CloudSyncV2WorkRegistration.isCanonicalScopeHash(scopeHash) ||
                expected?.scopeHash != scopeHash)) {
            result.success(false)
            return
        }
        controlScope.launch(start = CoroutineStart.UNDISPATCHED) {
            val accepted = runCatching {
                when (action) {
                    "configure" -> scopeHash != null &&
                        CloudSyncV2WorkRegistration.configure(context, scopeHash)
                    "hint" -> CloudSyncV2WorkRegistration.enqueue(context, kind!!, expected!!)
                    "disable" -> CloudSyncV2WorkRegistration.disable(context)
                    else -> false
                }
            }.getOrDefault(false)
            result.success(accepted)
        }
    }
}
