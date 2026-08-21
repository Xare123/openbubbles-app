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
import android.webkit.RenderProcessGoneDetail
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

        // Apple's onLeave notifier does not distinguish an explicit button tap
        // from an internal session transition. Finishing Android from every
        // notifier occurrence can therefore tear down a call during admission.
        // Bridge only an explicit tap on the web page's Leave control instead.
        private val leaveButtonBridgeScript = """
            (() => {
                const bridgeKey = "__openBubblesLeaveButtonBridge";
                if (window[bridgeKey]) return "already-installed";
                window[bridgeKey] = true;
                document.addEventListener("click", (event) => {
                    const button = event.target?.closest?.("button");
                    if (!button) return;
                    const label = (button.innerText || button.textContent || button.getAttribute?.("aria-label") || "").trim();
                    if (button.id === "callcontrols-leave-button-session-banner" || /^(leave|end call)$/i.test(label)) {
                        setTimeout(() => Native.leave(), 0);
                    }
                }, true);
                return "installed";
            })()
        """.trimIndent()
    }

    val webView = WebView(context)
    private val applicationContext = context.applicationContext
    private val allowedOrigin = secureWebOrigin(url)
    private val callbackHandler = Handler(Looper.getMainLooper())
    private var mirrorReadyRunnable: Runnable? = null

    var mirrorReady = false
    var mirrorReadyCall: (() -> Unit)? = null
    var endTask: () -> Unit = {
        webView.destroy()
        if (FaceTimeActivity.cachedWebview === this) {
            FaceTimeActivity.cachedWebview = null
            FaceTimeActivity.cachedCallUuid = null
        }
    }

    val deferredRequests = arrayListOf<PermissionRequest>()
    var deferredRequestsUpdated: () -> Unit = {}
    var deferredRequestCanceled: (PermissionRequest) -> Unit = {}

    fun cancelCallbacks() {
        mirrorReadyRunnable?.let(callbackHandler::removeCallbacks)
        mirrorReadyRunnable = null
        mirrorReadyCall = null
        deferredRequestsUpdated = {}
        deferredRequestCanceled = {}
        cancelDeferredPermissions()
    }

    fun cancelDeferredPermissions() {
        deferredRequests.toList().forEach { request ->
            runCatching { request.deny() }
        }
        deferredRequests.clear()
    }

    private fun safeResourceLabel(requestUrl: String?): String {
        if (requestUrl == null) return "unknown"
        return try {
            val uri = android.net.Uri.parse(requestUrl)
            val segment = uri.lastPathSegment.orEmpty()
            val resource = when {
                segment.endsWith(".js", ignoreCase = true) -> segment.substringAfterLast('/')
                segment.endsWith(".css", ignoreCase = true) -> segment.substringAfterLast('/')
                else -> "page-or-media"
            }
            "${uri.host ?: "unknown"}/$resource"
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
        val patch = FaceTimeWebCompatibility.patchMainScript(body.string(), name, desc)
        if (!patch.automaticJoinCompatible) {
            Log.e(
                diagnosticTag,
                "FaceTime web compatibility preflight failed submitName=${patch.submitNameMatches} nameProvided=${name != null}",
            )
        }

        FaceTimeDiagnostics.record(
            applicationContext,
            "web preflight bytes=${patch.script.length} waiting=${patch.waitingMatches} banner=${patch.bannerMatches} submitName=${patch.submitNameMatches} compatible=${patch.automaticJoinCompatible}",
        )

        if (diagnosticsEnabled()) {
            Log.i(
                diagnosticTag,
                "main.js bytes=${patch.script.length} patches waiting=${patch.waitingMatches} banner=${patch.bannerMatches} submitName=${patch.submitNameMatches} compatible=${patch.automaticJoinCompatible}"
            )
        }

        return patch.script
    }

    init {
        val client = OkHttpClient.Builder()
            .cache(
                Cache(
                    File(context.cacheDir, "http_cache"),
                    10L * 1024L * 1024L // 10 MiB
                )
            )
            .build()
        webView.settings.apply {
            javaScriptEnabled = true
            // Joining is initiated by our JavaScript bridge, which WebView does
            // not count as a user gesture. Allow the remote call audio/video to
            // start once FaceTime completes that programmatic join.
            mediaPlaybackRequiresUserGesture = false
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest?
            ): WebResourceResponse? {
                if (request == null) return null
                if (request.url.lastPathSegment != "main.js") {
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
                FaceTimeDiagnostics.record(
                    applicationContext,
                    "web page_started resource=${safeResourceLabel(url)}",
                )
                if (diagnosticsEnabled()) {
                    Log.i(diagnosticTag, "page started ${safeResourceLabel(url)}")
                }
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                view?.evaluateJavascript(leaveButtonBridgeScript) { result ->
                    if (diagnosticsEnabled()) {
                        Log.i(diagnosticTag, "leave button bridge result=$result")
                    }
                }
                FaceTimeDiagnostics.record(
                    applicationContext,
                    "web page_finished resource=${safeResourceLabel(url)} mirrorReady=$mirrorReady",
                )
                if (diagnosticsEnabled()) {
                    Log.i(diagnosticTag, "page finished ${safeResourceLabel(url)} mirrorReady=$mirrorReady")
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

            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                FaceTimeDiagnostics.record(
                    applicationContext,
                    "web renderer_gone crashed=${detail?.didCrash()} priority=${detail?.rendererPriorityAtExit()}",
                )
                Log.e(diagnosticTag, "WebView render process gone crashed=${detail?.didCrash()} priority=${detail?.rendererPriorityAtExit()}")
                callbackHandler.post { endTask() }
                return true
            }
        }
        webView.setBackgroundColor(Color.BLACK)

        webView.addJavascriptInterface(object {
            @JavascriptInterface
            fun leave() {
                Log.i(diagnosticTag, "explicit web leave control invoked")
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
                FaceTimeDiagnostics.record(
                    applicationContext,
                    "web mirrored_received ready_scheduled=true",
                )
                if (diagnosticsEnabled()) {
                    Log.i(diagnosticTag, "Native.mirrored received; mirrorReady scheduled")
                }
            }
        }, "Native")

        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
                if (request == null) return
                FaceTimeDiagnostics.record(
                    applicationContext,
                    "web permission_requested count=${request.resources.size} originAllowed=${matchesWebOrigin(allowedOrigin, request.origin.toString())}",
                )
                if (diagnosticsEnabled()) {
                    Log.i(diagnosticTag, "WebView permission request resources=${request.resources.sorted().joinToString()}")
                }
                if (!matchesWebOrigin(allowedOrigin, request.origin.toString()) ||
                    request.resources.any { it != PermissionRequest.RESOURCE_AUDIO_CAPTURE && it != PermissionRequest.RESOURCE_VIDEO_CAPTURE }
                ) {
                    Log.w(diagnosticTag, "denying WebView permission request from unexpected origin or resource")
                    request.deny()
                    return
                }
                deferredRequests.add(request)
                deferredRequestsUpdated()
            }

            override fun onPermissionRequestCanceled(request: PermissionRequest?) {
                if (request == null) return
                deferredRequests.remove(request)
                deferredRequestCanceled(request)
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
