package com.bluebubbles.messaging.services.facetime

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.telephony.SubscriptionManager
import android.util.Log
import androidx.core.app.ActivityCompat
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FaceTimeLaunchHandler: MethodCallHandlerImpl() {

    companion object {
        const val tag = "launch-facetime"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val requestedCallUuid = call.argument<String?>("callUuid")
        val activeCall = FaceTimeActivity.activeFaceTimeActivity
        if (
            requestedCallUuid != null &&
            activeCall?.callUuid == requestedCallUuid &&
            !activeCall.isFinishing &&
            !activeCall.isDestroyed
        ) {
            Log.i("FaceTimeDiag", "ignored duplicate launch for active call")
            result.success(null)
            return
        }

        val i = Intent(context, FaceTimeActivity::class.java)
        i.putExtra("link", call.argument<String>("link"))
        i.putExtra("desc", call.argument<String>("desc"))
        i.putExtra("name", call.argument<String?>("name"))
        i.putExtra("callUuid", requestedCallUuid)
        call.argument<Boolean?>("answer")?.let {
            i.putExtra("answer", it)
        }

        i.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        context.startActivity(i)

        result.success(null)
    }

}
