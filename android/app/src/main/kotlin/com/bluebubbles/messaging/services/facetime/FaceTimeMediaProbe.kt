package com.bluebubbles.messaging.services.facetime

import java.net.URI
import java.util.UUID

/** Reads only resolved samples from the trusted main frame. No JS interface is exposed. */
internal class FaceTimeMediaProbe(
    private val evaluate: (String, (String?) -> Unit) -> Unit,
    private val schedule: (Long, () -> Unit) -> Unit,
    private val currentUrl: () -> String?,
) {
    private class Request(val id: String, val callback: (String?) -> Unit)
    private var pending: Request? = null
    private var closed = false

    fun request(callback: (String?) -> Unit) {
        if (closed || pending != null || !isTrustedUrl(currentUrl())) {
            callback(null)
            return
        }
        val request = Request(UUID.randomUUID().toString(), callback)
        pending = request
        evaluate(startScript(request.id)) { result ->
            if (!isCurrent(request)) return@evaluate
            if (result != "\"started\"") {
                complete(request, null)
            } else {
                poll(request, 0)
            }
        }
        // Covers a missing evaluateJavascript callback as well as a hung getStats.
        schedule(timeoutMillis) { complete(request, null) }
    }

    private fun isCurrent(request: Request): Boolean = !closed && pending === request

    private fun complete(request: Request, result: String?) {
        if (!isCurrent(request)) return
        pending = null
        request.callback(if (isTrustedUrl(currentUrl())) result else null)
    }

    private fun poll(request: Request, attempt: Int) {
        if (!isCurrent(request)) return
        if (!isTrustedUrl(currentUrl())) {
            complete(request, null)
            return
        }
        evaluate(readScript(request.id)) { result ->
            if (!isCurrent(request)) return@evaluate
            if (result == "\"pending\"" && attempt < maxPolls) {
                schedule(pollMillis) { poll(request, attempt + 1) }
            } else {
                complete(request, result.takeUnless { it == "\"pending\"" })
            }
        }
    }

    /** Navigation invalidates the document and any previous call's pending sample. */
    fun invalidate() {
        val request = pending
        pending = null
        request?.callback?.invoke(null)
    }

    fun close() {
        closed = true
        pending = null
    }

    companion object {
        const val pollMillis = 100L
        const val maxPolls = 20
        const val timeoutMillis = 2500L

        internal fun canReusePage(cachedLink: String, cachedCallId: String?, link: String, callId: String?): Boolean =
            !callId.isNullOrBlank() && callId == cachedCallId && link == cachedLink

        internal fun isTrustedUrl(url: String?): Boolean = try {
            val uri = URI(url ?: "")
            uri.scheme == "https" && uri.host == "facetime.apple.com" &&
                (uri.port == -1 || uri.port == 443) && uri.rawUserInfo == null
        } catch (_: Exception) {
            false
        }

        internal fun startScript(requestId: String): String {
            require(requestId.matches(Regex("[a-zA-Z0-9-]+")))
            return """
                (() => {
                  if (window !== window.top || location.origin !== "https://facetime.apple.com") return "blocked";
                  const request = { id: "$requestId", ready: false, result: null };
                  window.__obFaceTimeMediaProbe = request;
                  Promise.resolve().then(() => {
                    const diagnostics = window.__obFaceTimeDiagnostics;
                    return diagnostics ? diagnostics.snapshot() : null;
                  }).then((result) => {
                    if (window.__obFaceTimeMediaProbe !== request || window !== window.top ||
                        location.origin !== "https://facetime.apple.com") return;
                    request.result = typeof result === "string" ? result : null;
                    request.ready = true;
                  }, () => {
                    if (window.__obFaceTimeMediaProbe === request) request.ready = true;
                  });
                  return "started";
                })()
            """.trimIndent()
        }

        internal fun readScript(requestId: String): String {
            require(requestId.matches(Regex("[a-zA-Z0-9-]+")))
            return """
                (() => {
                  if (window !== window.top || location.origin !== "https://facetime.apple.com") return null;
                  const request = window.__obFaceTimeMediaProbe;
                  if (!request || request.id !== "$requestId") return null;
                  if (!request.ready) return "pending";
                  delete window.__obFaceTimeMediaProbe;
                  return request.result;
                })()
            """.trimIndent()
        }
    }
}
