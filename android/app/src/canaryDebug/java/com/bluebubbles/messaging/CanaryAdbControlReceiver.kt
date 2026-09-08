package com.bluebubbles.messaging

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.util.Log
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler

/// Removable Canary-debug-only ADB control entry point.
///
/// This file lives under src/canaryDebug, so AGP compiles it ONLY into the
/// canaryDebug variant. Alpha, Beta, production, and canaryRelease APKs do
/// not contain this class or its manifest entry.
///
/// Trigger (localhost/ADB shell only):
///   adb shell am broadcast -n com.bluebubbles.messaging.cloudkitcanary/com.bluebubbles.messaging.CanaryAdbControlReceiver -a com.bluebubbles.messaging.CANARY_ADB --es action status --es seq 1
///
/// The receiver is android:exported="true" with
/// android:permission="android.permission.DUMP", declared ONLY in the
/// canaryDebug manifest overlay. exported=true is mandatory: on modern
/// Android the shell UID cannot deliver even an explicit broadcast to an
/// exported=false component. Shell-only scoping comes from the DUMP
/// permission (signature|privileged, pre-granted to the adb shell UID and
/// unobtainable by third-party apps, which get a SecurityException), plus
/// the variant check below, the action allowlist, and the Dart-side canary
/// package origin check. No intent-filter is declared.
/// No message content, identifiers, credentials, or network IO here: the
/// receiver forwards an allowlisted action string to Dart and returns an
/// immediate content-free acknowledgement via setResultData (visible as
/// data="..." in the am broadcast output). Detailed results are published by
/// Dart to private prefs + logcat under the CanaryAdb tag.
class CanaryAdbControlReceiver : BroadcastReceiver() {
    companion object {
        const val COMMAND_ACTION = "com.bluebubbles.messaging.CANARY_ADB"
        const val EXTRA_ACTION = "action"
        const val EXTRA_SEQ = "seq"
        const val EXTRA_CONFIRM = "confirm"
        const val EXTRA_CHALLENGE = "challenge"

        val ALLOWLIST = setOf(
            "ping",
            "status",
            "query_route",
            "open_developer_settings",
            "open_cloud_sync_v2",
            "semantic_pull_status",
            "semantic_pull_start",
        )

        private const val TAG = "CanaryAdb"
        private val TOKEN = Regex("^[A-Za-z0-9_-]{1,64}$")
        private val CHALLENGE = Regex("^c_[A-Za-z0-9_-]{27}$")
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        try {
            if (context == null || intent == null) {
                setResultData("{\"ok\":false,\"code\":\"adb_receiver_no_context\"}")
                return
            }
            // Belt-and-suspenders: this class only ships in canaryDebug, but
            // refuse explicitly if the runtime variant ever mismatches.
            val isDebuggable =
                context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
            if (context.packageName != "com.bluebubbles.messaging.cloudkitcanary" || !isDebuggable) {
                Log.w(TAG, "command_refused_variant")
                setResultData("{\"ok\":false,\"code\":\"adb_variant_refused\"}")
                return
            }
            val action = intent.getStringExtra(EXTRA_ACTION)
            val seq = intent.getStringExtra(EXTRA_SEQ) ?: "0"
            val confirm = intent.getStringExtra(EXTRA_CONFIRM) == "true"
            val challenge = intent.getStringExtra(EXTRA_CHALLENGE)
            if (action == null || action !in ALLOWLIST) {
                Log.w(TAG, "command_refused_action")
                setResultData("{\"ok\":false,\"code\":\"adb_action_unknown\"}")
                return
            }
            if (!TOKEN.matches(seq)) {
                Log.w(TAG, "command_refused_sequence")
                setResultData("{\"ok\":false,\"code\":\"adb_seq_invalid\"}")
                return
            }
            if (challenge != null && !CHALLENGE.matches(challenge)) {
                Log.w(TAG, "command_refused_challenge")
                setResultData("{\"ok\":false,\"code\":\"adb_challenge_invalid\"}")
                return
            }
            // Never start MainActivity here. Status, route and semantic actions
            // must not wake normal app lifecycle or its configured writer.
            if (MainActivity.engine == null || !MainActivity.engine_ready) {
                Log.i(TAG, "command_app_not_ready")
                setResultData("{\"ok\":false,\"code\":\"adb_app_not_ready\"}")
                return
            }
            try {
                val arguments = mutableMapOf<String, Any>(
                    "originPackage" to context.packageName,
                    "action" to action,
                    "seq" to seq,
                    "confirm" to confirm,
                )
                if (challenge != null) arguments["challenge"] = challenge
                MethodCallHandler.invokeMethod(
                    "canary-adb-command",
                    arguments,
                )
            } catch (_: Exception) {
                Log.w(TAG, "command_forward_failed")
                setResultData("{\"ok\":false,\"code\":\"adb_forward_failed\"}")
                return
            }
            val ack = "{\"ok\":true,\"code\":\"adb_received\",\"action\":\"" + action + "\",\"seq\":\"" + seq + "\"}"
            Log.i(TAG, "command_acknowledged")
            setResultData(ack)
        } catch (_: Exception) {
            try {
                Log.w(TAG, "command_receiver_failed")
                setResultData("{\"ok\":false,\"code\":\"adb_receiver_error\"}")
            } catch (ignored: Exception) {
            }
        }
    }
}
