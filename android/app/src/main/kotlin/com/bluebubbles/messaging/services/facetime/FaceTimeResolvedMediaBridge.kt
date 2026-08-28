package com.bluebubbles.messaging.services.facetime

/**
 * Starts an asynchronous WebRTC stats read and returns its resolved JSON over
 * the Native JavaScript interface. WebView.evaluateJavascript only observes
 * the immediate "requested" result; it must not be used for the async value.
 */
internal object FaceTimeResolvedMediaBridge {
    const val callbackTimeoutMillis = 2_500L

    fun requestScript(probeId: Long): String = """
        (() => {
            const probeId = $probeId;
            const fallback = JSON.stringify({peers:[]});
            const report = (value) => {
                try {
                    const payload = typeof value === "string" ? value : JSON.stringify(value);
                    Native.mediaEvidence(String(probeId), payload);
                } catch (_) {
                    try { Native.mediaEvidence(String(probeId), fallback); } catch (_) {}
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

    fun admissionRetryDiagnostic(success: Boolean): String =
        "activity admission_retry result=$success"
}
