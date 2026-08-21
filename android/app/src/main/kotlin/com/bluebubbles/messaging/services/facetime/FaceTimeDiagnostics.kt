package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.util.Log
import java.io.File
import java.net.URI
import java.util.concurrent.Executors

internal object FaceTimeDiagnostics {
    private const val tag = "FaceTimeDiag"
    private const val logFileName = "facetime_diagnostics.log"
    private const val maxLogBytes = 512L * 1024L
    private val fileLock = Any()
    private val fileWriter = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "FaceTimeDiagnostics").apply { isDaemon = true }
    }
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

    fun record(context: Context, message: String) {
        if (!isEnabled(context)) return
        val oneLineMessage = message.replace('\n', ' ').replace('\r', ' ')
        Log.w(tag, oneLineMessage)
        val filesDirectory = context.applicationContext.filesDir
        fileWriter.execute {
            synchronized(fileLock) {
                runCatching {
                    val directory = File(filesDirectory, "logs").apply { mkdirs() }
                    val file = File(directory, logFileName)
                    if (file.length() >= maxLogBytes) {
                        File(directory, "$logFileName.previous").delete()
                        file.renameTo(File(directory, "$logFileName.previous"))
                    }
                    file.appendText("${System.currentTimeMillis()} $oneLineMessage\n")
                }.onFailure { error ->
                    Log.w(tag, "unable to persist diagnostic event: ${error.javaClass.simpleName}")
                }
            }
        }
    }

    internal fun safeResourceLabel(requestUrl: String?): String {
        if (requestUrl == null) return "unknown"
        return try {
            val uri = URI(requestUrl)
            val segment = uri.path.orEmpty().substringAfterLast('/')
            val resource = when {
                segment.endsWith(".js", ignoreCase = true) -> segment
                segment.endsWith(".css", ignoreCase = true) -> segment
                else -> "page-or-media"
            }
            "${uri.host ?: "unknown"}/$resource"
        } catch (_: Exception) {
            "unparseable"
        }
    }
}
