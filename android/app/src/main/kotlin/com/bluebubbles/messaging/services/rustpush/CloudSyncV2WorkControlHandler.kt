package com.bluebubbles.messaging.services.rustpush

import android.content.Context
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart-to-Android control surface. It accepts no account or message data. */
class CloudSyncV2WorkControlHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "cloud-sync-v2-background-control"
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
        val accepted = when (call.argument<String>("action")) {
            "configure" -> {
                val scopeHash = call.argument<String>("scopeHash")
                if (scopeHash == null) false
                else CloudSyncV2WorkRegistration.configure(context, scopeHash)
            }
            "hint" -> {
                val kind = runCatching {
                    CloudSyncV2WorkKind.valueOf(call.argument<String>("kind") ?: "")
                }.getOrNull()
                kind != null && CloudSyncV2WorkRegistration.enqueue(context, kind)
            }
            "disable" -> CloudSyncV2WorkRegistration.disable(context)
            else -> false
        }
        result.success(accepted)
    }
}
