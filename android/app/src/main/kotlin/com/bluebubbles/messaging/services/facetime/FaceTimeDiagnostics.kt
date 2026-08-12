package com.bluebubbles.messaging.services.facetime

import android.content.Context

internal object FaceTimeDiagnostics {
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
}
