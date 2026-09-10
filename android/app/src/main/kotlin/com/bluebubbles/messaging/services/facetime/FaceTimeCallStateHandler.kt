package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.content.Intent
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FaceTimeCallStateHandler: MethodCallHandlerImpl() {

    companion object {
        const val tag = "update-call-state"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val state = call.argument<String>("state")

        if (state == "ringing") {
            if (FaceTimeActivity.activeFaceTimeActivity == null && FaceTimeActivity.cachedWebview == null) {
                val name = call.argument<String>("name")
                val desc = call.argument<String>("desc")!!
                val url = call.argument<String>("url")!!
                // start preloading the FT web UI now so if they pick up the call we're ready
                FaceTimeActivity.cachedWebview = CachedWebview(context, name, desc, url, call.argument<String>("callUuid"))
            }
        } else if (state == "timeout") {
            val callUuid = call.argument<String>("callUuid")
            // Late cancellation of a previous call must not close a newer call.
            FaceTimeActivity.activeFaceTimeActivity?.let {
                if (FaceTimeTimeoutPolicy.shouldFinishActivity(callUuid, it.callUuid, it.answered, it.isCall)) {
                    FaceTimeDiagnostics.logStage(context, FaceTimeDiagnosticStage.CLOSE_REASON, state = "ring_timeout")
                    it.finishAndRemoveTask()
                }
            }
            // Discard only the unused page belonging to this terminal event.
            FaceTimeActivity.cachedWebview?.takeIf { it.matchesCallId(callUuid) }?.let {
                it.cancelCallbacks()
                it.webView.destroy()
                FaceTimeActivity.cachedWebview = null
            }
        }

        result.success(null)
    }

}
