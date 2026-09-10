package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.util.Log
import io.flutter.util.PathUtils
import java.io.File

internal object FaceTimeDiagnostics {
    private const val diagnosticTag = "FaceTimeDiag"
    private const val preferencesName = "FlutterSharedPreferences"
    private const val developerModeKey = "flutter.developerEnabled"
    private const val diagnosticsKey = "flutter.faceTimeDiagnosticsEnabled"
    private var writer: FaceTimeDiagnosticLog? = null

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
    ): Boolean = FaceTimeDiagnosticPolicy.shouldEnable(developerModeEnabled, diagnosticsEnabled)

    internal fun formatStage(
        stage: FaceTimeDiagnosticStage,
        state: String? = null,
        count: Int? = null,
        bytes: Long? = null,
    ): String = FaceTimeDiagnosticPolicy.formatStage(stage, state, count, bytes)

    @Synchronized
    internal fun logStage(
        context: Context,
        stage: FaceTimeDiagnosticStage,
        state: String? = null,
        count: Int? = null,
        bytes: Long? = null,
    ) {
        try {
            if (!isEnabled(context)) return
            val app = context.applicationContext
            val log = writer ?: FaceTimeDiagnosticLog(
                // Same PathUtils call used by path_provider_android for appDocDir.
                // A subdirectory is essential: Dart AdvancedFileOutput prunes all root files.
                File(PathUtils.getDataDirectory(app), "logs/facetime-native"),
                enabled = { isEnabled(app) },
            ).also { writer = it }
            if (log.record(stage, state, count, bytes)) {
                Log.i(diagnosticTag, formatStage(stage, state, count, bytes))
            }
        } catch (_: Exception) {
            // Opt-in diagnostics must never interfere with a call, including End.
        }
    }

    internal fun safeIceState(rawValue: String?): String =
        FaceTimeDiagnosticPolicy.safeState(FaceTimeDiagnosticStage.ICE_STATE, rawValue ?: "unknown")
}
