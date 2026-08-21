package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.content.Intent
import android.util.Log
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal fun shouldFinishFaceTimeActivity(
    state: String?,
    isCall: Boolean,
    answered: Boolean,
    activityCallUuid: String?,
    requestedCallUuid: String?,
): Boolean = state == "timeout" &&
    isCall &&
    !answered &&
    requestedCallUuid != null &&
    activityCallUuid == requestedCallUuid

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
        val activeActivity = FaceTimeActivity.activeFaceTimeActivity

        if (FaceTimeDiagnostics.isEnabled(context)) {
            Log.w(
                "FaceTimeDiag",
                "native call state=$state active=${activeActivity != null} answered=${activeActivity?.answered} uuidMatches=${callUuid != null && activeActivity?.callUuid == callUuid}",
            )
        }

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
            // Rust's native participant can leave while Apple's WebRTC guest is
            // still joining. Treat timeout as terminal only while ringing; the
            // joined WebView or its explicit End action owns answered-call exit.
            activeActivity?.let {
                if (shouldFinishFaceTimeActivity(state, it.isCall, it.answered, it.callUuid, callUuid)) {
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
