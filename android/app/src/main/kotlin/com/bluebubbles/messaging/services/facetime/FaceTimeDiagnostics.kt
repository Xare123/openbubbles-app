package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.util.Log

internal enum class FaceTimeDiagnosticStage(val wireName: String) {
    WEBVIEW_LOADED("webview_loaded"),
    JS_PATCHED("js_patched"),
    PERMISSIONS_REQUESTED("permissions_requested"),
    PERMISSIONS_RESULT("permissions_result"),
    ADMISSION_REQUESTED("admission_requested"),
    ADMITTED("admitted"),
    ICE_STATE("ice_state"),
    REMOTE_AUDIO_TRACK("remote_audio_track"),
    REMOTE_VIDEO_TRACK("remote_video_track"),
    MEDIA_BYTES("media_bytes"),
    MEDIA_LOST("media_lost"),
    LEAVE("leave"),
    LIFECYCLE("lifecycle"),
}

internal object FaceTimeDiagnostics {
    private const val diagnosticTag = "FaceTimeDiag"
    private const val preferencesName = "FlutterSharedPreferences"
    private const val developerModeKey = "flutter.developerEnabled"
    private const val diagnosticsKey = "flutter.faceTimeDiagnosticsEnabled"

    fun isEnabled(context: Context): Boolean {
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        return shouldEnable(
            developerModeEnabled = preferences.getBoolean(developerModeKey, false),
            diagnosticsEnabled = preferences.getBoolean(diagnosticsKey, false),
        )
    }

    internal fun shouldEnable(
        developerModeEnabled: Boolean,
        diagnosticsEnabled: Boolean,
    ): Boolean = developerModeEnabled && diagnosticsEnabled

    internal fun formatStage(
        stage: FaceTimeDiagnosticStage,
        state: String? = null,
        count: Int? = null,
        bytes: Long? = null,
    ): String {
        val fields = buildList {
            add("stage=${stage.wireName}")
            state?.let { add("state=${safeValue(it)}") }
            count?.let { add("count=${it.coerceAtLeast(0)}") }
            bytes?.let { add("bytes=${it.coerceAtLeast(0)}") }
        }
        return fields.joinToString(" ")
    }

    internal fun logStage(
        context: Context,
        stage: FaceTimeDiagnosticStage,
        state: String? = null,
        count: Int? = null,
        bytes: Long? = null,
    ) {
        if (isEnabled(context)) {
            Log.i(diagnosticTag, formatStage(stage, state, count, bytes))
        }
    }

    internal fun safeIceState(rawValue: String?): String = when (rawValue?.lowercase()) {
        "new", "checking", "connected", "completed", "disconnected", "failed", "closed" -> rawValue.lowercase()
        else -> "unknown"
    }

    private fun safeValue(value: String): String = value
        .lowercase()
        .replace(Regex("[^a-z0-9_.-]"), "_")
}
