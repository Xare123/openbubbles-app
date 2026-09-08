package com.bluebubbles.messaging

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler

/// Removable Canary-debug-only ADB control entry point.
///
/// This file lives under src/canaryDebug, so AGP compiles it ONLY into the
/// canaryDebug variant. Alpha, Beta, production, and canaryRelease APKs do
/// not contain this class or its manifest entry.
///
/// Trigger (localhost/ADB shell only; the host script also launches the app
/// first because background activity starts from a receiver are blocked on
/// modern Android, so the receiver-side launch below is best-effort only):
///   adb shell am start -n com.bluebubbles.messaging.cloudkitcanary/com.bluebubbles.messaging.MainActivity
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
        private const val PREFS = "FlutterSharedPreferences"
        private const val PENDING_KEY = "flutter.canary_adb_pending"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        try {
            if (context == null || intent == null) {
                setResultData("{\"ok\":false,\"code\":\"adb_receiver_no_context\"}")
                return
            }
            // Belt-and-suspenders: this class only ships in canaryDebug, but
            // refuse explicitly if the runtime variant ever mismatches.
            if (BuildConfig.FLAVOR != "canary" || !BuildConfig.DEBUG) {
                Log.w(TAG, "refusing canary ADB command on variant=" + BuildConfig.FLAVOR)
                setResultData("{\"ok\":false,\"code\":\"adb_variant_refused\"}")
                return
            }
            val action = intent.getStringExtra(EXTRA_ACTION)
            val seq = intent.getStringExtra(EXTRA_SEQ) ?: "0"
            val confirm = intent.getStringExtra(EXTRA_CONFIRM) == "true"
            if (action == null || action !in ALLOWLIST) {
                val ack = "{\"ok\":false,\"code\":\"adb_action_unknown\",\"seq\":\"" + safeToken(seq) + "\"}"
                Log.w(TAG, "unknown canary ADB action seq=" + safeToken(seq))
                setResultData(ack)
                return
            }
            if (action == "open_developer_settings" || action == "open_cloud_sync_v2") {
                // Persist for cold start: if the Dart engine is not up yet,
                // the Dart dispatcher drains this on init.
                context.getSharedPreferences(PREFS, 0).edit()
                    .putString(PENDING_KEY, action + "|" + safeToken(seq))
                    .apply()
                // Best-effort foreground only: the host script launches the
                // app explicitly first, because background activity starts
                // from a receiver are blocked on modern Android.
                try {
                    val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                    if (launch != null) {
                        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(launch)
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "launch failed seq=" + safeToken(seq) + ": " + e.message)
                }
            }
            // Forward to Dart. Fire-and-forget: MainActivity.engine is null on
            // cold start, in which case the pending entry above covers open_*
            // actions and query actions report app_not_running.
            try {
                MethodCallHandler.invokeMethod(
                    "canary-adb-command",
                    mapOf(
                        "originPackage" to context.packageName,
                        "action" to action,
                        "seq" to safeToken(seq),
                        "confirm" to confirm,
                    ),
                )
            } catch (e: Exception) {
                Log.w(TAG, "forward failed seq=" + safeToken(seq) + ": " + e.message)
            }
            val ack = "{\"ok\":true,\"code\":\"adb_received\",\"action\":\"" + action + "\",\"seq\":\"" + safeToken(seq) + "\"}"
            Log.i(TAG, "ack " + ack)
            setResultData(ack)
        } catch (e: Exception) {
            try {
                setResultData("{\"ok\":false,\"code\":\"adb_receiver_error\"}")
            } catch (ignored: Exception) {
            }
        }
    }

    private fun safeToken(raw: String): String {
        if (raw.length > 64) return raw.substring(0, 64).filter { it.isLetterOrDigit() || it == '_' || it == '-' }
        return raw.filter { it.isLetterOrDigit() || it == '_' || it == '-' }
    }
}
