package com.bluebubbles.messaging.services.facetime

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import okhttp3.Cache
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayInputStream
import java.io.File
import java.net.URI
import java.util.UUID

@SuppressLint("SetJavaScriptEnabled")
class CachedWebview(context: Context, name: String?, desc: String, url: String) {
    companion object {
        private const val diagnosticTag = "FaceTimeDiag"
        private const val faceTimePageHost = "facetime.apple.com"
        private val trustedResourceDomains = setOf("apple.com", "icloud.com")

        private fun trustedHttpsHost(url: String): String? = try {
            val uri = URI(url)
            if (!uri.scheme.equals("https", ignoreCase = true) ||
                uri.rawUserInfo != null ||
                uri.port !in listOf(-1, 443)
            ) {
                null
            } else {
                uri.host?.lowercase()?.trimEnd('.')
            }
        } catch (_: Exception) {
            null
        }

        internal fun isTrustedFaceTimePageUrl(url: String): Boolean =
            trustedHttpsHost(url) == faceTimePageHost

        internal fun isTrustedFaceTimeResourceUrl(url: String): Boolean {
            val host = trustedHttpsHost(url) ?: return false
            return trustedResourceDomains.any { domain ->
                host == domain || host.endsWith(".$domain")
            }
        }

        internal fun isMainBundleUrl(url: String): Boolean {
            if (!isTrustedFaceTimeResourceUrl(url)) return false
            val path = try {
                URI(url).path
            } catch (_: Exception) {
                null
            } ?: return false
            return path.substringAfterLast('/').equals("main.js", ignoreCase = true)
        }

        /**
         * Return a JavaScript string literal for values supplied by the user.
         *
         * This deliberately follows JSON string escaping, which is also valid
         * JavaScript, and additionally escapes the two Unicode line separators
         * that are valid JSON but terminate a classic JavaScript string literal.
         */
        internal fun javascriptStringLiteral(value: String): String = buildString {
            append('"')
            var index = 0
            while (index < value.length) {
                val character = value[index]
                when (character) {
                    '"' -> append("\\\"")
                    '\\' -> append("\\\\")
                    '\b' -> append("\\b")
                    '\u000C' -> append("\\f")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    '\u2028', '\u2029' -> append(
                        "\\u${character.code.toString(16).padStart(4, '0')}"
                    )
                    in '\u0000'..'\u001F' -> append(
                        "\\u${character.code.toString(16).padStart(4, '0')}"
                    )
                    in '\uD800'..'\uDBFF' -> {
                        val lowSurrogate = value.getOrNull(index + 1)
                        if (lowSurrogate != null && lowSurrogate in '\uDC00'..'\uDFFF') {
                            append(character)
                            append(lowSurrogate)
                            index++
                        } else {
                            append("\\u${character.code.toString(16).padStart(4, '0')}")
                        }
                    }
                    in '\uDC00'..'\uDFFF' -> append(
                        "\\u${character.code.toString(16).padStart(4, '0')}"
                    )
                    else -> append(character)
                }
                index++
            }
            append('"')
        }
    }

    val webView = WebView(context)
    private val applicationContext = context.applicationContext
    private val callbackHandler = Handler(Looper.getMainLooper())
    private var mirrorReadyRunnable: Runnable? = null
    private val mediaEvidenceGate = FaceTimeResolvedMediaCallbackGate()
    private val webLeaveVisibilityGate = FaceTimeWebLeaveVisibilityGate()
    @Volatile
    private var latestWebLeaveVisibility: Boolean? = null
    @Volatile
    private var callbackGeneration = 0L
    @Volatile
    private var currentPageTrusted = isTrustedFaceTimePageUrl(url)
    private val bridgeToken = UUID.randomUUID().toString()

    private fun isCurrentPageTrusted(): Boolean = currentPageTrusted

    var mirrorReady = false
    var mirrorReadyCall: (() -> Unit)? = null
    var mediaEvidenceCall: (Long, String) -> Unit = { _, _ -> }
    var webLeaveVisibilityCall: (Boolean) -> Unit = {}
    var endTask: () -> Unit = {
        webView.destroy()
        FaceTimeActivity.cachedWebview = null
    }

    val deferredRequests = arrayListOf<PermissionRequest>()
    var deferredRequestsUpdated: () -> Unit = {}

    fun cancelCallbacks() {
        callbackGeneration += 1
        mirrorReadyRunnable?.let(callbackHandler::removeCallbacks)
        mirrorReadyRunnable = null
        mirrorReadyCall = null
        mediaEvidenceGate.reset()
        mediaEvidenceCall = { _, _ -> }
        webLeaveVisibilityGate.reset()
        latestWebLeaveVisibility = null
        webLeaveVisibilityCall = {}
        deferredRequestsUpdated = {}
    }

    fun expectMediaEvidence(probeId: Long): Boolean = mediaEvidenceGate.expect(probeId)

    fun cancelMediaEvidenceProbe(probeId: Long) {
        mediaEvidenceGate.cancel(probeId)
    }

    fun currentWebLeaveVisibility(): Boolean? = latestWebLeaveVisibility

    private fun safeResourceLabel(requestUrl: String?): String {
        if (requestUrl == null) return "unknown"
        return try {
            val uri = android.net.Uri.parse(requestUrl)
            val segment = uri.lastPathSegment.orEmpty()
            when {
                segment.endsWith(".js", ignoreCase = true) -> "script"
                segment.endsWith(".css", ignoreCase = true) -> "style"
                else -> "page-or-media"
            }
        } catch (_: Exception) {
            "unparseable"
        }
    }

    private fun diagnosticsEnabled(): Boolean = FaceTimeDiagnostics.isEnabled(applicationContext)

    fun getScriptData(request: WebResourceRequest, client: OkHttpClient, name: String?, desc: String): String {
        if (diagnosticsEnabled()) Log.i(diagnosticTag, "getting main.js")
        // OKHTTP should handle caching for us
        val okhttp = Request.Builder()
            .method(request.method, null)
            .headers(request.requestHeaders.entries.fold(Headers.Builder()) { acc, e ->
                acc.set(e.key, e.value)
                acc
            }.build())
            .url(request.url.toString())
            .build()

        val call = client.newCall(okhttp)
        val response = call.execute()
        if (response.code() != 200) {
            throw Exception("Failed to load resource! $response")
        }
        val body = response.body() ?: throw Exception("Failed to load resource! Empty body!")
        var string = body.string()
        val waitingPattern = """"GenericToast\.Waiting": *"Waiting to be let in…",""".toRegex()
        val bannerPattern = """"SessionBanner\.FaceTime": *"FaceTime Call",""".toRegex()
        val submitNamePattern = "(submitName: *([a-zA-Z]+?)[ a-zA-Z,}=:]*?;)".toRegex()
        val diagnosticsEnabled = diagnosticsEnabled()
        val waitingMatches = if (diagnosticsEnabled) waitingPattern.findAll(string).count() else 0
        val bannerMatches = if (diagnosticsEnabled) bannerPattern.findAll(string).count() else 0
        val leaveMatches = if (diagnosticsEnabled) "this.onLeave.notifyListeners()".toRegex().findAll(string).count() else 0
        val submitNameMatches = if (diagnosticsEnabled && name != null) submitNamePattern.findAll(string).count() else 0

        string = string
            .replace(""""GenericToast\.Waiting": *"Waiting to be let in…",""".toRegex(), """"GenericToast.Waiting":"Connecting…",""")
            .replace(""""SessionBanner\.FaceTime": *"FaceTime Call",""".toRegex(), """"SessionBanner.FaceTime":"$desc",""")
            .replace(
                "this.onLeave.notifyListeners()",
                "window.__obFaceTimeNativeEvent?.(\"leave\"), this.onLeave.notifyListeners()",
            )

        if (name != null) {
            val javascriptName = javascriptStringLiteral(name)
            string = string.replace(submitNamePattern) { match ->
                "${match.groupValues[1]} ${match.groupValues[2]}($javascriptName).then(() => window.__obFaceTimeNativeEvent?.(\"mirrored\"));"
            }
        }

        val patchCount = waitingMatches + bannerMatches + leaveMatches + submitNameMatches
        if (diagnosticsEnabled) {
            FaceTimeDiagnostics.logStage(
                applicationContext,
                FaceTimeDiagnosticStage.JS_PATCHED,
                state = if (patchCount > 0) "true" else "false",
                count = patchCount,
            )
        }

        return webRtcDiagnosticBootstrap + string
    }

    private val webRtcDiagnosticBootstrap = """
        (() => {
          if (window.top !== window.self) return;
          if (window.__obFaceTimeDiagnostics) return;
          const nativeBridgeToken = "__OB_NATIVE_BRIDGE_TOKEN__";
          const sendNativeEvent = (event, first = "", second = "") => {
            try {
              if (event === "leave") Native.leave(nativeBridgeToken);
              else if (event === "mirrored") Native.mirrored(nativeBridgeToken);
              else if (event === "media-evidence") Native.mediaEvidence(nativeBridgeToken, first, second);
              else if (event === "web-leave-visibility") Native.webLeaveVisibility(nativeBridgeToken, first);
            } catch (_) {}
          };
          window.__obFaceTimeNativeEvent = sendNativeEvent;
          const state = {
            peers: [],
            nextPeerId: 1,
            leaveObserver: null,
            lastReportedLeaveVisible: null,
          };
          const updateIceState = (peerState) => {
            peerState.iceState = peerState.peer.iceConnectionState || peerState.peer.connectionState || "unknown";
          };
          const watchPeer = (pc) => {
            const peerState = {
              id: state.nextPeerId++,
              peer: pc,
              iceState: "unknown",
              previousInboundBytes: null,
              previousVideoFramesDecoded: null,
              previousAudioDecodedSamples: null,
              previousAudioJitterBufferEmittedCount: null,
              remoteAudioTracks: new Map(),
              remoteVideoTracks: new Map()
            };
            state.peers.push(peerState);
            updateIceState(peerState);
            const refreshConnectionState = () => {
              updateIceState(peerState);
              if (peerState.iceState === "closed") {
                state.peers = state.peers.filter((candidate) => candidate !== peerState);
              }
            };
            pc.addEventListener("iceconnectionstatechange", refreshConnectionState);
            pc.addEventListener("connectionstatechange", refreshConnectionState);
            pc.addEventListener("track", (event) => {
              if (!event.track || !event.track.id) return;
              const tracks = event.track.kind === "audio"
                ? peerState.remoteAudioTracks
                : event.track.kind === "video" ? peerState.remoteVideoTracks : null;
              if (!tracks) return;
              const track = event.track;
              tracks.set(track.id, track);
              track.addEventListener("ended", () => {
                if (tracks.get(track.id) === track) tracks.delete(track.id);
              });
            });
          };
          const install = () => {
            const original = window.RTCPeerConnection;
            if (!original || window.__obFaceTimeRtcWrapped) return !!original;
            window.__obFaceTimeRtcWrapped = true;
            window.RTCPeerConnection = new Proxy(original, {
              construct(target, args, newTarget) {
                const peer = Reflect.construct(target, args, newTarget);
                watchPeer(peer);
                return peer;
              }
            });
            return true;
          };
          const controlText = (button) =>
            (button.innerText || button.textContent || button.getAttribute("aria-label") || "")
              .trim()
              .replace(/\s+/g, " ")
              .toLowerCase();
          const isVisible = (button) => {
            if (!button || button.hidden === true || button.getAttribute("aria-hidden") === "true") {
              return false;
            }
            const style = typeof window.getComputedStyle === "function"
              ? window.getComputedStyle(button)
              : null;
            if (style && (
              style.display === "none" ||
              style.visibility === "hidden" ||
              style.visibility === "collapse" ||
              Number.parseFloat(style.opacity || "1") === 0
            )) {
              return false;
            }
            if (typeof button.getBoundingClientRect !== "function") return true;
            const bounds = button.getBoundingClientRect();
            return bounds.width > 0 && bounds.height > 0;
          };
          const controlState = (names) => {
            const matches = Array.from(document.querySelectorAll("button"))
              .filter((button) => names.includes(controlText(button)));
            const visible = matches.some((button) => isVisible(button));
            const enabled = matches.some((button) =>
              isVisible(button) &&
              button.disabled !== true &&
              button.getAttribute("aria-disabled") !== "true"
            );
            return { visible, enabled, count: matches.length };
          };
          const sendLeaveVisibility = (visible) => {
            if (state.lastReportedLeaveVisible === visible) return;
            sendNativeEvent("web-leave-visibility", visible ? "true" : "false");
            state.lastReportedLeaveVisible = visible;
          };
          const reportLeaveVisibility = () => {
            const visible = controlState(["leave", "end call"]).visible;
            sendLeaveVisibility(visible);
          };
          const installLeaveObserver = () => {
            if (state.leaveObserver || typeof window.MutationObserver !== "function" || !document.documentElement) {
              return false;
            }
            state.leaveObserver = new window.MutationObserver(reportLeaveVisibility);
            state.leaveObserver.observe(document.documentElement, {
              attributes: true,
              attributeFilter: ["aria-hidden", "aria-label", "class", "hidden", "style"],
              characterData: true,
              childList: true,
              subtree: true,
            });
            window.addEventListener("resize", reportLeaveVisibility, { passive: true });
            reportLeaveVisibility();
            return true;
          };
          install();
          if (!installLeaveObserver() && document.addEventListener) {
            document.addEventListener("DOMContentLoaded", installLeaveObserver, { once: true });
          }
          if (!window.__obFaceTimeRtcInstallTimer) {
            window.__obFaceTimeRtcInstallTimer = window.setInterval(() => {
              if (install()) window.clearInterval(window.__obFaceTimeRtcInstallTimer);
            }, 100);
          }
          window.__obFaceTimeDiagnostics = {
            snapshot: async () => {
              const candidates = [];
              for (const peerState of state.peers) {
                updateIceState(peerState);
                if (peerState.iceState === "closed") continue;
                let bytes = 0;
                let bytesObserved = false;
                let videoFramesDecoded = 0;
                let videoFramesDecodedObserved = false;
                let audioSamplesReceived = 0;
                let audioSamplesReceivedObserved = false;
                let audioConcealedSamples = 0;
                let audioConcealedSamplesObserved = false;
                let audioJitterBufferEmittedCount = 0;
                let audioJitterBufferEmittedCountObserved = false;
                const peer = peerState.peer;
                try {
                  const reports = await peer.getStats();
                  reports.forEach((report) => {
                    if (report.type === "inbound-rtp" && typeof report.bytesReceived === "number") {
                      bytes += report.bytesReceived;
                      bytesObserved = true;
                    }
                    if (report.type !== "inbound-rtp") return;
                    const kind = report.kind || report.mediaType || null;
                    if ((kind === "video" || kind === null) && typeof report.framesDecoded === "number") {
                      videoFramesDecoded += report.framesDecoded;
                      videoFramesDecodedObserved = true;
                    }
                    const isAudio = kind === "audio" ||
                      (kind === null && typeof report.totalSamplesReceived === "number");
                    if (isAudio && typeof report.totalSamplesReceived === "number") {
                      audioSamplesReceived += report.totalSamplesReceived;
                      audioSamplesReceivedObserved = true;
                    }
                    if (isAudio && typeof report.concealedSamples === "number") {
                      audioConcealedSamples += report.concealedSamples;
                      audioConcealedSamplesObserved = true;
                    }
                    if (isAudio && typeof report.jitterBufferEmittedCount === "number") {
                      audioJitterBufferEmittedCount += report.jitterBufferEmittedCount;
                      audioJitterBufferEmittedCountObserved = true;
                    }
                  });
                } catch (_) {}
                const remoteAudioTracks = Array.from(peerState.remoteAudioTracks.values())
                  .filter((track) => track.readyState !== "ended").length;
                const remoteVideoTracks = Array.from(peerState.remoteVideoTracks.values())
                  .filter((track) => track.readyState !== "ended").length;
                const bytesAdvancing = bytesObserved &&
                  peerState.previousInboundBytes !== null &&
                  bytes > peerState.previousInboundBytes;
                const audioDecodedSamples = audioSamplesReceivedObserved
                  ? Math.max(0, audioSamplesReceived - (audioConcealedSamplesObserved ? audioConcealedSamples : 0))
                  : null;
                const decodedAdvancing = (
                  videoFramesDecodedObserved &&
                  peerState.previousVideoFramesDecoded !== null &&
                  videoFramesDecoded > peerState.previousVideoFramesDecoded
                ) || (
                  audioDecodedSamples !== null &&
                  peerState.previousAudioDecodedSamples !== null &&
                  audioDecodedSamples > peerState.previousAudioDecodedSamples
                ) || (
                  audioJitterBufferEmittedCountObserved &&
                  peerState.previousAudioJitterBufferEmittedCount !== null &&
                  audioJitterBufferEmittedCount > peerState.previousAudioJitterBufferEmittedCount
                );
                peerState.previousInboundBytes = bytesObserved ? bytes : null;
                peerState.previousVideoFramesDecoded = videoFramesDecodedObserved ? videoFramesDecoded : null;
                peerState.previousAudioDecodedSamples = audioDecodedSamples;
                peerState.previousAudioJitterBufferEmittedCount = audioJitterBufferEmittedCountObserved
                  ? audioJitterBufferEmittedCount
                  : null;
                candidates.push({
                  peerId: peerState.id,
                  iceState: peerState.iceState,
                  remoteAudioTracks,
                  remoteVideoTracks,
                  mediaBytes: bytesObserved ? bytes : null,
                  videoFramesDecoded: videoFramesDecodedObserved ? videoFramesDecoded : null,
                  audioSamplesReceived: audioSamplesReceivedObserved ? audioSamplesReceived : null,
                  audioConcealedSamples: audioConcealedSamplesObserved ? audioConcealedSamples : null,
                  audioJitterBufferEmittedCount: audioJitterBufferEmittedCountObserved
                    ? audioJitterBufferEmittedCount
                    : null,
                  bytesAdvancing,
                  decodedAdvancing,
                  connectedWithTrack: (peerState.iceState === "connected" || peerState.iceState === "completed") &&
                    remoteAudioTracks + remoteVideoTracks > 0,
                });
              }
              const latest = candidates.at(-1) || null;
              const latestIsTerminal = latest &&
                (latest.iceState === "failed" || latest.iceState === "closed");
              const advancing = [...candidates].reverse().find((candidate) => candidate.decodedAdvancing)
                || [...candidates].reverse().find((candidate) => candidate.bytesAdvancing)
                || null;
              const newestConnectedWithTrack = [...candidates].reverse()
                .find((candidate) => candidate.connectedWithTrack) || null;
              const active = latestIsTerminal
                ? (advancing || latest)
                : (newestConnectedWithTrack || advancing || latest);
              const controls = {
                join: controlState(["join"]),
                rejoin: controlState(["rejoin"]),
                leave: controlState(["leave", "end call"]),
              };
              return JSON.stringify({
                peerId: active ? active.peerId : null,
                iceState: active ? active.iceState : "unknown",
                remoteAudioTracks: active ? active.remoteAudioTracks : 0,
                remoteVideoTracks: active ? active.remoteVideoTracks : 0,
                mediaBytes: active ? active.mediaBytes : null,
                ...(active && active.videoFramesDecoded !== null
                  ? { videoFramesDecoded: active.videoFramesDecoded } : {}),
                ...(active && active.audioSamplesReceived !== null
                  ? { audioSamplesReceived: active.audioSamplesReceived } : {}),
                ...(active && active.audioConcealedSamples !== null
                  ? { audioConcealedSamples: active.audioConcealedSamples } : {}),
                ...(active && active.audioJitterBufferEmittedCount !== null
                  ? { audioJitterBufferEmittedCount: active.audioJitterBufferEmittedCount } : {}),
                webLeaveVisible: controls.leave.visible,
                webControls: controls
              });
            }
          };
        })();
    """.trimIndent().replace(
        "\"__OB_NATIVE_BRIDGE_TOKEN__\"",
        javascriptStringLiteral(bridgeToken),
    )

    init {
        val client = OkHttpClient.Builder()
            .cache(
                Cache(
                    File(context.cacheDir, "http_cache"),
                    10L * 1024L * 1024L // 10 MiB
                )
            )
            .build()
        webView.settings.javaScriptEnabled = true
        webView.settings.allowFileAccess = false
        webView.settings.allowContentAccess = false
        webView.settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        webView.settings.javaScriptCanOpenWindowsAutomatically = false
        webView.settings.setSupportMultipleWindows(false)
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?,
            ): Boolean {
                if (request == null || !request.isForMainFrame) return false
                val trusted = isTrustedFaceTimePageUrl(request.url.toString())
                if (!trusted && diagnosticsEnabled()) {
                    Log.w(diagnosticTag, "blocked untrusted main-frame navigation")
                }
                return !trusted
            }

            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest?
            ): WebResourceResponse? {
                if (request == null) return null
                if (!isMainBundleUrl(request.url.toString())) {
                    if (diagnosticsEnabled() && request.url.lastPathSegment?.equals("main.js", ignoreCase = true) == true) {
                        Log.w(diagnosticTag, "main.js candidate was not intercepted because its URL has a suffix")
                    }
                    return null
                }
                // intercept and patch request

                if (diagnosticsEnabled()) {
                    Log.i(diagnosticTag, "intercepting ${safeResourceLabel(request.url.toString())}")
                }
                val scriptData = try {
                    getScriptData(request, client, name, desc)
                } catch (error: Exception) {
                    if (diagnosticsEnabled()) {
                        Log.e(diagnosticTag, "main.js interception failed: ${error.javaClass.simpleName}")
                    }
                    throw error
                }

                return WebResourceResponse(
                    "application/javascript",
                    "utf-8",
                    ByteArrayInputStream(scriptData.encodeToByteArray())
                )
            }

            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                currentPageTrusted = url?.let(::isTrustedFaceTimePageUrl) == true
                if (diagnosticsEnabled()) {
                    Log.i(diagnosticTag, "page started ${safeResourceLabel(url)}")
                }
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                if (diagnosticsEnabled() && url?.let(::isTrustedFaceTimePageUrl) == true) {
                    FaceTimeDiagnostics.logStage(
                        applicationContext,
                        FaceTimeDiagnosticStage.WEBVIEW_LOADED,
                        state = "true",
                    )
                }
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?
            ) {
                if (diagnosticsEnabled()) {
                    Log.w(
                        diagnosticTag,
                        "resource error mainFrame=${request?.isForMainFrame} code=${error?.errorCode} resource=${safeResourceLabel(request?.url?.toString())}"
                    )
                }
            }

            override fun onReceivedHttpError(
                view: WebView?,
                request: WebResourceRequest?,
                errorResponse: WebResourceResponse?
            ) {
                if (diagnosticsEnabled()) {
                    Log.w(
                        diagnosticTag,
                        "http error mainFrame=${request?.isForMainFrame} status=${errorResponse?.statusCode} resource=${safeResourceLabel(request?.url?.toString())}"
                    )
                }
            }
        }
        webView.setBackgroundColor(Color.BLACK)

        webView.addJavascriptInterface(object {
            @JavascriptInterface
            fun leave(token: String?) {
                if (token != bridgeToken || !isCurrentPageTrusted()) return
                callbackHandler.post { endTask() }
            }
            @JavascriptInterface
            fun mirrored(token: String?) {
                if (token != bridgeToken || !isCurrentPageTrusted()) return
                if (mirrorReady || mirrorReadyRunnable != null) {
                    if (diagnosticsEnabled()) {
                        Log.i(diagnosticTag, "duplicate Native.mirrored ignored")
                    }
                    return
                }
                // takes a second for the mirror to be ready
                val runnable = Runnable {
                    mirrorReadyRunnable = null
                    mirrorReady = true
                    mirrorReadyCall?.let {
                        it()
                    }
                }
                mirrorReadyRunnable = runnable
                callbackHandler.postDelayed(runnable, 250)
                if (diagnosticsEnabled()) {
                    Log.i(diagnosticTag, "Native.mirrored received; mirrorReady scheduled")
                }
            }
            @JavascriptInterface
            fun mediaEvidence(token: String?, probeId: String?, payload: String?) {
                if (token != bridgeToken || !isCurrentPageTrusted()) return
                // evaluateJavascript does not await Promise results. The page
                // resolves getStats first, then sends only this bounded JSON
                // payload over the existing same-page Native bridge.
                val safeProbeId = probeId?.toLongOrNull()?.takeIf { it > 0 } ?: return
                val boundedPayload = payload?.takeIf {
                    it.length <= FaceTimeResolvedMediaBridge.maxCallbackPayloadLength
                } ?: return
                if (!mediaEvidenceGate.accept(safeProbeId, boundedPayload)) return
                val generation = callbackGeneration
                callbackHandler.post {
                    if (callbackGeneration == generation) {
                        mediaEvidenceCall(safeProbeId, boundedPayload)
                    }
                }
            }
            @JavascriptInterface
            fun webLeaveVisibility(token: String?, rawVisible: String?) {
                if (token != bridgeToken || !isCurrentPageTrusted()) return
                val visible = webLeaveVisibilityGate.accept(rawVisible) ?: return
                latestWebLeaveVisibility = visible
                val generation = callbackGeneration
                callbackHandler.post {
                    if (callbackGeneration == generation) {
                        webLeaveVisibilityCall(visible)
                    }
                }
            }
        }, "Native")

        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
                if (request == null) return
                if (!isTrustedFaceTimePageUrl(request.origin.toString()) || !isCurrentPageTrusted()) {
                    if (diagnosticsEnabled()) {
                        Log.w(diagnosticTag, "rejected WebView permission request from untrusted origin")
                    }
                    request.deny()
                    return
                }
                if (diagnosticsEnabled()) {
                    FaceTimeDiagnostics.logStage(
                        applicationContext,
                        FaceTimeDiagnosticStage.PERMISSIONS_REQUESTED,
                        count = request.resources.size,
                    )
                }
                deferredRequests.add(request)
                deferredRequestsUpdated()
            }

            override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean {
                if (!diagnosticsEnabled() || consoleMessage == null) return false
                if (consoleMessage.messageLevel() == ConsoleMessage.MessageLevel.ERROR ||
                    consoleMessage.messageLevel() == ConsoleMessage.MessageLevel.WARNING) {
                    Log.w(
                        diagnosticTag,
                        "console ${consoleMessage.messageLevel()} line=${consoleMessage.lineNumber()} source=${safeResourceLabel(consoleMessage.sourceId())} message=<omitted>"
                    )
                }
                return false
            }

            override fun getDefaultVideoPoster(): Bitmap {
                return Bitmap.createBitmap(1, 1, Bitmap.Config.RGB_565)
            }
        }

        if (isTrustedFaceTimePageUrl(url)) {
            webView.loadUrl(url)
        } else {
            if (diagnosticsEnabled()) {
                Log.w(diagnosticTag, "refused to load untrusted FaceTime URL")
            }
            webView.loadData("<html><body></body></html>", "text/html", "utf-8")
        }
    }

}
