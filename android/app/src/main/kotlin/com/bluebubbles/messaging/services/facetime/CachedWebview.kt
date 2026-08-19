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

    private fun diagnosticsEnabled(): Boolean = FaceTimeDiagnostics.isEnabled(applicationContext)

    private fun safeResourceLabel(requestUrl: String?): String = FaceTimeDiagnostics.safeResourceLabel(requestUrl)

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
        val waitingMatches = waitingPattern.findAll(string).count()
        val bannerMatches = bannerPattern.findAll(string).count()
        val leaveMatches = "this.onLeave.notifyListeners()".toRegex().findAll(string).count()
        val submitNameMatches = if (name != null) submitNamePattern.findAll(string).count() else 0

        string = string
            .replace(""""GenericToast\.Waiting": *"Waiting to be let in…",""".toRegex(), """"GenericToast.Waiting":"Connecting…",""")
            .replace(""""SessionBanner\.FaceTime": *"FaceTime Call",""".toRegex(), """"SessionBanner.FaceTime":${javascriptStringLiteral(desc)},""")
            .replace("this.onLeave.notifyListeners()", "Native.leave(), this.onLeave.notifyListeners()")

        if (name != null) {
            string = string.replace(submitNamePattern, "$1 $2(${javascriptStringLiteral(name)}).then(() => Native.mirrored());")
        }

        if (leaveMatches == 0 || (name != null && submitNameMatches == 0)) {
            Log.e(
                diagnosticTag,
                "FaceTime web compatibility patch missing leave=$leaveMatches submitName=$submitNameMatches nameProvided=${name != null}",
            )
        }

        Log.i(
            diagnosticTag,
            "main.js bytes=${string.length} patches waiting=$waitingMatches banner=$bannerMatches leave=$leaveMatches submitName=$submitNameMatches nameProvided=${name != null}"
        )

        return string
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
        webView.settings.javaScriptEnabled = true
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

                if (diagnosticsEnabled()) Log.i(diagnosticTag, "intercepting ${safeResourceLabel(request.url.toString())}")
                val scriptData = try {
                    getScriptData(request, client, name, desc)
                } catch (error: Exception) {
                    if (diagnosticsEnabled()) Log.e(diagnosticTag, "main.js interception failed: ${error.javaClass.simpleName}")
                    throw error
                }

                return WebResourceResponse(
                    "application/javascript",
                    "utf-8",
                    ByteArrayInputStream(scriptData.encodeToByteArray())
                )
            }

            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                if (diagnosticsEnabled()) Log.i(diagnosticTag, "page started ${safeResourceLabel(url)}")
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                if (diagnosticsEnabled()) Log.i(diagnosticTag, "page finished ${safeResourceLabel(url)} mirrorReady=$mirrorReady")
            }

            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                if (diagnosticsEnabled()) Log.w(diagnosticTag, "resource error mainFrame=${request?.isForMainFrame} code=${error?.errorCode} resource=${safeResourceLabel(request?.url?.toString())}")
            }

            override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?) {
                if (diagnosticsEnabled()) Log.w(diagnosticTag, "http error mainFrame=${request?.isForMainFrame} status=${errorResponse?.statusCode} resource=${safeResourceLabel(request?.url?.toString())}")
            }

            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                Log.e(diagnosticTag, "WebView render process gone crashed=${detail?.didCrash()} priority=${detail?.rendererPriorityAtExit()}")
                callbackHandler.post { endTask() }
                return true
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
                    Log.i(diagnosticTag, "duplicate Native.mirrored ignored")
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
                if (diagnosticsEnabled()) Log.i(diagnosticTag, "Native.mirrored received; mirrorReady scheduled")
            }
        }, "Native")

        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
                if (request == null) return
                if (diagnosticsEnabled()) Log.i(diagnosticTag, "WebView permission request resources=${request.resources.sorted().joinToString()}")
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
                if (consoleMessage.messageLevel() == ConsoleMessage.MessageLevel.ERROR || consoleMessage.messageLevel() == ConsoleMessage.MessageLevel.WARNING) {
                    Log.w(diagnosticTag, "console ${consoleMessage.messageLevel()} line=${consoleMessage.lineNumber()} source=${safeResourceLabel(consoleMessage.sourceId())} message=<omitted>")
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
