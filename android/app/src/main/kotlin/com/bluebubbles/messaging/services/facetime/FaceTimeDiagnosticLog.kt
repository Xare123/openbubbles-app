package com.bluebubbles.messaging.services.facetime

import java.io.File
import java.io.FileOutputStream
import java.util.Locale

internal enum class FaceTimeDiagnosticStage(val wireName: String) {
    WEBVIEW_LOADED("webview_loaded"), JS_PATCHED("js_patched"),
    PERMISSIONS_REQUESTED("permissions_requested"), PERMISSIONS_RESULT("permissions_result"),
    ADMISSION_REQUESTED("admission_requested"), ADMITTED("admitted"), ICE_STATE("ice_state"),
    REMOTE_AUDIO_TRACK("remote_audio_track"), REMOTE_VIDEO_TRACK("remote_video_track"),
    MEDIA_BYTES("media_bytes"), MEDIA_LOST("media_lost"), LEAVE("leave"),
    LIFECYCLE("lifecycle"), CLOSE_REASON("close_reason"), MEDIA_PROBE("media_probe"),
}

/** Reject free text, rather than replacing punctuation in potentially secret values. */
internal object FaceTimeDiagnosticPolicy {
    fun shouldEnable(developerModeEnabled: Boolean, diagnosticsEnabled: Boolean): Boolean =
        developerModeEnabled && diagnosticsEnabled

    private val states = mapOf(
        FaceTimeDiagnosticStage.WEBVIEW_LOADED to setOf("true"),
        FaceTimeDiagnosticStage.JS_PATCHED to setOf("true", "false"),
        FaceTimeDiagnosticStage.PERMISSIONS_RESULT to setOf("granted", "denied"),
        FaceTimeDiagnosticStage.ADMISSION_REQUESTED to setOf(
            "answer", "outgoing", "clicked", "already_joined", "missing", "disabled", "hidden", "unknown",
        ),
        FaceTimeDiagnosticStage.ADMITTED to setOf("true"),
        FaceTimeDiagnosticStage.ICE_STATE to setOf(
            "new", "checking", "connected", "completed", "disconnected", "failed", "closed", "unknown",
        ),
        FaceTimeDiagnosticStage.MEDIA_LOST to setOf("media_pending", "media_failed"),
        FaceTimeDiagnosticStage.LEAVE to setOf("requested", "web_callback", "clicked", "missing"),
        FaceTimeDiagnosticStage.LIFECYCLE to setOf(
            "created", "destroyed", "configuration_destroyed", "finishing_destroyed", "stopped", "paused",
            "accepted", "duplicate_intent", "ignored_intent", "missing_call_id",
        ),
        FaceTimeDiagnosticStage.CLOSE_REASON to setOf("native_end_fallback", "web_leave", "declined", "ring_timeout"),
        FaceTimeDiagnosticStage.MEDIA_PROBE to setOf("unavailable", "sampled", "exhausted", "document_changed"),
    )

    fun safeState(stage: FaceTimeDiagnosticStage, value: String): String {
        if (value.length > 48) return "unknown"
        val normalized = value.lowercase(Locale.ROOT)
        return normalized.takeIf { it in states[stage].orEmpty() } ?: "unknown"
    }

    fun formatStage(stage: FaceTimeDiagnosticStage, state: String? = null, count: Int? = null, bytes: Long? = null,
        evidence: FaceTimeMediaEvidence? = null): String =
        buildList {
            add("stage=${stage.wireName}")
            state?.let { add("state=${safeState(stage, it)}") }
            if (stage in setOf(FaceTimeDiagnosticStage.JS_PATCHED, FaceTimeDiagnosticStage.PERMISSIONS_REQUESTED,
                    FaceTimeDiagnosticStage.ADMISSION_REQUESTED, FaceTimeDiagnosticStage.REMOTE_AUDIO_TRACK,
                    FaceTimeDiagnosticStage.REMOTE_VIDEO_TRACK)) {
                count?.let { add("count=${it.coerceIn(0, 65535)}") }
            }
            if (stage == FaceTimeDiagnosticStage.MEDIA_BYTES) bytes?.let { add("bytes=${it.coerceAtLeast(0)}") }
            // One resolved sample, not independently throttled counters from different peers.
            // peer is a document-local ordinal, never a call/account/track identifier.
            if (stage == FaceTimeDiagnosticStage.MEDIA_PROBE && state == "sampled" && evidence != null) {
                add("peer=${evidence.peerId?.takeIf { it > 0 } ?: "none"}")
                add("ice=${safeState(FaceTimeDiagnosticStage.ICE_STATE, evidence.iceState.name)}")
                add("audio=${evidence.remoteAudioTracks.coerceIn(0, 65535)}")
                add("video=${evidence.remoteVideoTracks.coerceIn(0, 65535)}")
                add("bytes=${evidence.mediaBytes?.takeIf { it >= 0 } ?: "unavailable"}")
            }
        }.joinToString(" ")
}

/** One process-owned writer, no captures, raw strings, asynchronous backlog or Dart dependency.
 * The existing Download / Share Logs and Clear Logs explicitly include these two generations.
 * Close each append before returning so a normal process restart does not lose buffered events.
 */
internal class FaceTimeDiagnosticLog(
    private val directory: File,
    private val enabled: () -> Boolean,
    private val monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000 },
    private val wallMillis: () -> Long = System::currentTimeMillis,
    private val maxFileBytes: Long = 64 * 1024,
) {
    companion object {
        const val currentName = "facetime-native.log"
        const val previousName = "facetime-native-previous.log"
        const val maxLineBytes = 256
    }

    private data class Last(val time: Long, val line: String)
    // Keys contain only enum stages and allowlisted states, never caller-controlled identifiers.
    private val last = mutableMapOf<Pair<FaceTimeDiagnosticStage, String?>, Last>()

    @Synchronized
    fun record(stage: FaceTimeDiagnosticStage, state: String? = null, count: Int? = null, bytes: Long? = null,
        evidence: FaceTimeMediaEvidence? = null): Boolean {
        try {
            if (!enabled()) {
                last.clear()
                return false
            }
            val line = FaceTimeDiagnosticPolicy.formatStage(stage, state, count, bytes, evidence)
            val key = stage to state?.let { FaceTimeDiagnosticPolicy.safeState(stage, it) }
            val now = monotonicMillis()
            val prior = last[key]
            // At most one changed sample per second per finite stage/state, or one unchanged
            // heartbeat per 15 seconds. Close reasons have their own keys, so media cannot starve them.
            val interval = if (prior?.line == line && stage !in setOf(
                    FaceTimeDiagnosticStage.CLOSE_REASON, FaceTimeDiagnosticStage.LEAVE, FaceTimeDiagnosticStage.LIFECYCLE,
                )) 15000L else 1000L
            if (prior != null && now >= prior.time && now - prior.time < interval) return false
            val encoded = ("time_ms=${wallMillis().coerceAtLeast(0)} $line\n").toByteArray(Charsets.UTF_8)
            if (encoded.size > maxLineBytes || encoded.size > maxFileBytes) return false
            if (!directory.isDirectory && !directory.mkdirs()) return false
            val current = File(directory, currentName)
            val previous = File(directory, previousName)
            // Fixed targets only. Never prune other logger files or captures.
            if (previous.length() > maxFileBytes && !previous.delete()) return false
            if (current.length() > maxFileBytes && !current.delete()) return false
            if (current.length() + encoded.size > maxFileBytes) {
                if (previous.exists() && !previous.delete()) return false
                if (!current.renameTo(previous)) return false
            }
            FileOutputStream(current, true).use {
                it.write(encoded)
                if (stage == FaceTimeDiagnosticStage.CLOSE_REASON) it.fd.sync()
            }
            last[key] = Last(now, line)
            return true
        } catch (_: Exception) {
            // Diagnostics must not break admission, media or End. Never log an exception body/path.
            return false
        }
    }
}
