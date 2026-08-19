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
        val callUuid = call.argument<String>("callUuid")

        if (state == "ringing") {
            if (FaceTimeActivity.activeFaceTimeActivity == null) {
                val name = call.argument<String>("name")
                val desc = call.argument<String>("desc")!!
                val url = call.argument<String>("url")!!
                if (FaceTimeActivity.cachedWebview != null && FaceTimeActivity.cachedCallUuid != callUuid) {
                    FaceTimeActivity.cachedWebview?.let { stale ->
                        stale.cancelCallbacks()
                        stale.webView.destroy()
                    }
                    FaceTimeActivity.cachedWebview = null
                    FaceTimeActivity.cachedCallUuid = null
                }
                if (FaceTimeActivity.cachedWebview == null) {
                    // Keep the preloaded page tied to the call/link that created it.
                    FaceTimeActivity.cachedWebview = CachedWebview(context, name, desc, url)
                    FaceTimeActivity.cachedCallUuid = callUuid
                }
            }
        } else if (state == "timeout") {
            // finish any still ringing activity
            FaceTimeActivity.activeFaceTimeActivity?.let {
                if (!it.answered && it.isCall && it.callUuid == callUuid) {
                    it.finishAndRemoveTask()
                }
            }
            // A stale timer from another call must not destroy the current cache.
            if (FaceTimeActivity.cachedCallUuid == callUuid) {
                FaceTimeActivity.cachedWebview?.let {
                    it.cancelCallbacks()
                    it.webView.destroy()
                    FaceTimeActivity.cachedWebview = null
                    FaceTimeActivity.cachedCallUuid = null
                }
            }
        }

        result.success(null)
    }

}
