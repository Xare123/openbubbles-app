package com.bluebubbles.messaging.services.facetime

/**
 * Bridges the asynchronous WebRTC stats result back to Android.
 *
 * WebView.evaluateJavascript returns immediately and cannot await a Promise,
 * so media evidence must be delivered through the page's existing Native
 * JavaScript interface after getStats resolves.
 */
internal object FaceTimeResolvedMediaBridge {
    const val callbackTimeoutMillis = 2_500L
    const val maxCallbackPayloadLength = 16 * 1024

    fun requestScript(probeId: Long): String = """
        (() => {
            const probeId = $probeId;
            const fallback = JSON.stringify({peerId:null,iceState:"unknown",remoteAudioTracks:0,remoteVideoTracks:0,mediaBytes:null,webLeaveVisible:false});
            const report = (value) => {
                try {
                    const payload = typeof value === "string" ? value : JSON.stringify(value);
                    window.__obFaceTimeNativeEvent?.("media-evidence", String(probeId), payload);
                } catch (_) {
                    try { window.__obFaceTimeNativeEvent?.("media-evidence", String(probeId), fallback); } catch (_) {}
                }
            };
            if (!window.__obFaceTimeDiagnostics || !window.__obFaceTimeDiagnostics.snapshot) {
                report(fallback);
                return "requested";
            }
            Promise.resolve(window.__obFaceTimeDiagnostics.snapshot())
                .then(report)
                .catch(() => report(fallback));
            return "requested";
        })()
    """.trimIndent()
}

/**
 * Correlates the one async page callback expected for each stats probe before
 * it is posted to the main thread. WebView JavaScript interfaces are invoked
 * off-main, so this object is deliberately small and synchronized.
 */
internal class FaceTimeResolvedMediaCallbackGate {
    private var expectedProbeId: Long? = null
    private var deliveredProbeId: Long? = null

    @Synchronized
    fun expect(probeId: Long): Boolean {
        if (probeId <= 0) return false
        expectedProbeId = probeId
        deliveredProbeId = null
        return true
    }

    @Synchronized
    fun accept(probeId: Long, payload: String): Boolean {
        if (probeId <= 0 || payload.length > FaceTimeResolvedMediaBridge.maxCallbackPayloadLength) {
            return false
        }
        if (expectedProbeId != probeId || deliveredProbeId == probeId) return false

        deliveredProbeId = probeId
        expectedProbeId = null
        return true
    }

    @Synchronized
    fun cancel(probeId: Long) {
        if (expectedProbeId == probeId) {
            expectedProbeId = null
        }
    }

    @Synchronized
    fun reset() {
        expectedProbeId = null
        deliveredProbeId = null
    }
}

/**
 * Bounds and deduplicates event-driven DOM visibility updates before they
 * reach Android's main thread. The Activity owns the delayed native-fallback
 * transition so a newer visible event can always cancel it.
 */
internal class FaceTimeWebLeaveVisibilityGate {
    companion object {
        const val showFallbackStabilityMillis = 500L
    }

    private var lastAcceptedVisibility: Boolean? = null

    @Synchronized
    fun accept(rawVisible: String?): Boolean? {
        val visible = when (rawVisible) {
            "true" -> true
            "false" -> false
            else -> return null
        }
        if (lastAcceptedVisibility == visible) return null

        lastAcceptedVisibility = visible
        return visible
    }

    @Synchronized
    fun reset() {
        lastAcceptedVisibility = null
    }
}
