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
import android.webkit.WebView
import android.webkit.WebViewClient
import okhttp3.Cache
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayInputStream
import java.io.File

@SuppressLint("SetJavaScriptEnabled")
class CachedWebview(context: Context, name: String?, desc: String, url: String) {
    companion object {
        private const val diagnosticTag = "FaceTimeDiag"
    }

    val webView = WebView(context)
    private val applicationContext = context.applicationContext
    private val callbackHandler = Handler(Looper.getMainLooper())
    private var mirrorReadyRunnable: Runnable? = null

    var mirrorReady = false
    var mirrorReadyCall: (() -> Unit)? = null
    var endTask: () -> Unit = {
        webView.destroy()
        FaceTimeActivity.cachedWebview = null
    }

    val deferredRequests = arrayListOf<PermissionRequest>()
    var deferredRequestsUpdated: () -> Unit = {}

    fun cancelCallbacks() {
        mirrorReadyRunnable?.let(callbackHandler::removeCallbacks)
        mirrorReadyRunnable = null
        mirrorReadyCall = null
        deferredRequestsUpdated = {}
    }

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
            .replace("this.onLeave.notifyListeners()", "Native.leave(), this.onLeave.notifyListeners()")

        if (name != null) {
            string = string.replace(submitNamePattern, "$1 $2(\"$name\").then(() => Native.mirrored());")
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
          if (window.__obFaceTimeDiagnostics) return;
          const state = {
            peers: [],
          };
          const updateIceState = (peerState) => {
            peerState.iceState = peerState.peer.iceConnectionState || peerState.peer.connectionState || "unknown";
          };
          const watchPeer = (pc) => {
            const peerState = {
              peer: pc,
              iceState: "unknown",
              remoteAudioTracks: new Map(),
              remoteVideoTracks: new Map()
            };
            state.peers.push(peerState);
            updateIceState(peerState);
            pc.addEventListener("iceconnectionstatechange", () => updateIceState(peerState));
            pc.addEventListener("connectionstatechange", () => updateIceState(peerState));
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
          install();
          if (!window.__obFaceTimeRtcInstallTimer) {
            window.__obFaceTimeRtcInstallTimer = window.setInterval(() => {
              if (install()) window.clearInterval(window.__obFaceTimeRtcInstallTimer);
            }, 100);
          }
          window.__obFaceTimeDiagnostics = {
            snapshot: async () => {
              let bytes = 0;
              let bytesObserved = false;
              for (const peerState of state.peers) {
                const peer = peerState.peer;
                updateIceState(peerState);
                try {
                  const reports = await peer.getStats();
                  reports.forEach((report) => {
                    if (report.type === "inbound-rtp" && typeof report.bytesReceived === "number") {
                      bytes += report.bytesReceived;
                      bytesObserved = true;
                    }
                  });
                } catch (_) {}
              }
              const currentStates = state.peers.map((peerState) => peerState.iceState);
              const preferredStates = ["connected", "completed", "checking", "new", "disconnected", "failed", "closed"];
              const iceState = preferredStates.find((candidate) => currentStates.includes(candidate)) || "unknown";
              const remoteAudioTracks = state.peers.reduce((count, peerState) => {
                return count + Array.from(peerState.remoteAudioTracks.values()).filter((track) => track.readyState !== "ended").length;
              }, 0);
              const remoteVideoTracks = state.peers.reduce((count, peerState) => {
                return count + Array.from(peerState.remoteVideoTracks.values()).filter((track) => track.readyState !== "ended").length;
              }, 0);
              const leave = Array.from(document.querySelectorAll("button")).some((button) => {
                const text = (button.innerText || button.textContent || button.getAttribute("aria-label") || "").trim();
                return /^(leave|end call)$/i.test(text) && button.offsetParent !== null;
              });
              return JSON.stringify({
                iceState,
                remoteAudioTracks,
                remoteVideoTracks,
                mediaBytes: bytesObserved ? bytes : null,
                webLeaveVisible: leave
              });
            }
          };
        })();
    """.trimIndent()

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
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest?
            ): WebResourceResponse? {
                if (request == null) return null
                if (!request.url.toString().endsWith("main.js")) {
                    if (diagnosticsEnabled() && request.url.lastPathSegment == "main.js") {
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
                if (diagnosticsEnabled()) {
                    Log.i(diagnosticTag, "page started ${safeResourceLabel(url)}")
                }
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                if (diagnosticsEnabled()) {
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
            fun leave() {
                callbackHandler.post { endTask() }
            }
            @JavascriptInterface
            fun mirrored() {
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
        }, "Native")

        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
                if (request == null) return
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

        webView.loadUrl(url)
    }

}
