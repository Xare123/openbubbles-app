package com.bluebubbles.messaging.services.facetime

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.database.ContentObserver
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.Rational
import android.view.View
import android.view.ViewGroup.MarginLayoutParams
import android.view.WindowInsets
import android.view.WindowManager
import android.webkit.PermissionRequest
import android.webkit.WebView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.marginTop
import androidx.core.view.updateLayoutParams
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.databinding.ActivityFaceTimeBinding
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.bluebubbles.messaging.services.notifications.CreateIncomingFaceTimeNotification
import com.bluebubbles.messaging.services.notifications.DeleteNotificationHandler
import com.bluebubbles.messaging.services.rustpush.APNClient
import com.bluebubbles.messaging.services.rustpush.APNService
import com.bluebubbles.messaging.utils.getStreamMinVolumeCompat
import com.google.android.material.math.MathUtils
import kotlin.math.roundToInt

internal fun hasRequiredFaceTimeLaunchData(link: String?): Boolean = !link.isNullOrBlank()

class FaceTimeActivity : Activity() {
    companion object {
        private const val diagnosticTag = "FaceTimeDiag"
        var activeFaceTimeActivity: FaceTimeActivity? = null
        var cachedWebview: CachedWebview? = null
        var cachedCallUuid: String? = null
    }

    private lateinit var binding: ActivityFaceTimeBinding

    private var permissionRequests = ArrayList<PermissionRequest>()
    private var permissionRequestInFlight = false
    private val deniedAndroidPermissions = mutableSetOf<String>()
    private val permissionMap = mapOf(
        PermissionRequest.RESOURCE_VIDEO_CAPTURE to listOf(Manifest.permission.CAMERA),
        PermissionRequest.RESOURCE_AUDIO_CAPTURE to listOf(Manifest.permission.RECORD_AUDIO),
    )
    var isCall = false
    var answered = false
    private var mirrorReady = false
    private var notificationId = 0
    var callUuid: String? = null
    private lateinit var cached: CachedWebview

    private lateinit var webView: WebView
    private var initialMediaVolume: Int? = null;
    private val mainHandler = Handler(Looper.getMainLooper())
    private val joinPolicy = FaceTimeJoinPolicy()
    private var joinRetryRunnable: Runnable? = null
    private var manualRecoveryRunnable: Runnable? = null
    private var connectionProbeRunnable: Runnable? = null
    private var connectionProbeWatchdogRunnable: Runnable? = null
    private var endFallbackRunnable: Runnable? = null
    private var connectionProbeCount = 0
    private var connectionProbeStartedAtMillis: Long? = null
    private var nextConnectionProbeId = 0L
    private var awaitingConnectionProbeId: Long? = null
    private var callEnding = false
    private var rendererAvailable = true
    private val localEndReporter = FaceTimeLocalEndReporter()
    private val lifecycleEndPolicy = FaceTimeLifecycleEndPolicy()
    private val manualAdmissionRetryState = FaceTimeAdmissionRetryState()

    private fun diagnosticsEnabled(): Boolean = FaceTimeDiagnostics.isEnabled(this)

    private val joinButtonScript = """
        (() => {
            const visible = (element) => !!element && element.offsetParent !== null;
            const label = (element) => (element?.innerText || element?.textContent || element?.getAttribute?.("aria-label") || "").trim();
            const buttons = Array.from(document.querySelectorAll("button"));
            const leave = document.getElementById("callcontrols-leave-button-session-banner") ||
                buttons.find((button) => /^(leave|end call)$/i.test(label(button)));
            if (visible(leave)) return JSON.stringify({outcome:"already-joined",leaveVisible:true});
            const join = document.getElementById("callcontrols-join-button-session-banner") ||
                buttons.find((button) => /^(join|rejoin)$/i.test(label(button)));
            if (!join) return JSON.stringify({outcome:"missing",leaveVisible:false});
            if (join.disabled || join.getAttribute("aria-disabled") === "true") return JSON.stringify({outcome:"disabled",leaveVisible:false});
            if (!visible(join)) return JSON.stringify({outcome:"hidden",leaveVisible:false});
            join.click();
            return JSON.stringify({outcome:"clicked",leaveVisible:false});
        })()
    """.trimIndent()

    private fun logJoinButtonState(reason: String) {
        if (!diagnosticsEnabled()) return
        webView.evaluateJavascript(
            """(() => { const button = document.getElementById("callcontrols-join-button-session-banner"); return button ? "present:" + (!button.disabled) + ":" + (button.offsetParent !== null) : "missing"; })()"""
        ) { result ->
            if (diagnosticsEnabled()) {
                val buttonPresent = result?.removeSurrounding("\"")?.startsWith("present:") == true
                Log.i(diagnosticTag, "join button state reason=$reason present=$buttonPresent mirrorReady=$mirrorReady answered=$answered")
            }
        }
    }

    private fun showCallUi(joined: Boolean) {
        binding.mainFrame.visibility = View.VISIBLE
        binding.splashLayout.visibility = View.GONE
        // Keep an Android-owned end control visible for the entire call. It is
        // deliberately bottom-centered in the layout so it cannot overlap
        // Apple's top controls, and remains usable if the web Leave button is
        // absent or the join signal is wrong.
        binding.nativeCallControls.visibility = View.VISIBLE
        binding.connectionStatus.visibility = if (joined) View.GONE else View.VISIBLE
        if (!joined) {
            binding.connectionStatus.text = "Finishing FaceTime connection..."
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            window.setBackgroundBlurRadius(0)
        }
    }

    private fun scheduleConnectionProbe(delayMillis: Long = 0) {
        val startedAt = connectionProbeStartedAtMillis
            ?: SystemClock.elapsedRealtime().also { connectionProbeStartedAtMillis = it }
        if (!FaceTimeConnectionProbePolicy.shouldContinue(
                probeCount = connectionProbeCount,
                elapsedMillis = (SystemClock.elapsedRealtime() - startedAt).coerceAtLeast(0L),
                joined = joinPolicy.joined,
                ending = callEnding || isFinishing,
                destroyed = isDestroyed,
            )
        ) return
        connectionProbeRunnable?.let(mainHandler::removeCallbacks)
        val runnable = Runnable {
            val elapsedMillis = (SystemClock.elapsedRealtime() - startedAt).coerceAtLeast(0L)
            if (!FaceTimeConnectionProbePolicy.shouldContinue(
                    probeCount = connectionProbeCount,
                    elapsedMillis = elapsedMillis,
                    joined = joinPolicy.joined,
                    ending = callEnding || isFinishing,
                    destroyed = isDestroyed,
                )
            ) return@Runnable
            val probeId = ++nextConnectionProbeId
            awaitingConnectionProbeId = probeId
            connectionProbeWatchdogRunnable?.let(mainHandler::removeCallbacks)
            val watchdog = Runnable {
                if (awaitingConnectionProbeId == probeId) {
                    onResolvedMediaEvidence(probeId, "{\"peers\":[]}")
                }
            }
            connectionProbeWatchdogRunnable = watchdog
            mainHandler.postDelayed(watchdog, FaceTimeResolvedMediaBridge.callbackTimeoutMillis)
            webView.evaluateJavascript(FaceTimeResolvedMediaBridge.requestScript(probeId), null)
        }
        connectionProbeRunnable = runnable
        mainHandler.postDelayed(runnable, delayMillis)
    }

    private fun onResolvedMediaEvidence(probeId: Long, payload: String) {
        if (callEnding || joinPolicy.joined || isFinishing || isDestroyed) return
        if (awaitingConnectionProbeId != probeId) return
        awaitingConnectionProbeId = null
        connectionProbeWatchdogRunnable?.let(mainHandler::removeCallbacks)
        connectionProbeWatchdogRunnable = null
        connectionProbeCount += 1
        val evidence = FaceTimeMediaEvidenceParser.parse(payload)
        if (evidence == null) {
            if (diagnosticsEnabled()) {
                FaceTimeDiagnostics.record(this, "activity media_probe attempt=$connectionProbeCount result=unavailable")
            }
            scheduleConnectionProbe(FaceTimeConnectionProbePolicy.pendingDelayMillis)
            return
        }
        if (diagnosticsEnabled()) {
            val peerCount = evidence.peerSamples().size
            val remoteTrackCount = evidence.peerSamples().sumOf { it.remoteAudioTracks + it.remoteVideoTracks }
            FaceTimeDiagnostics.record(
                this,
                "activity media_probe attempt=$connectionProbeCount peers=$peerCount remoteTracks=$remoteTrackCount",
            )
        }
        val decision = joinPolicy.recordMediaEvidence(evidence)
        if (decision.joined) {
            joinRetryRunnable?.let(mainHandler::removeCallbacks)
            stopConnectionProbing()
        }
        showCallUi(joined = decision.joined)
        if (!decision.joined) {
            scheduleConnectionProbe(FaceTimeConnectionProbePolicy.pendingDelayMillis)
        }
    }

    private fun stopConnectionProbing() {
        connectionProbeRunnable?.let(mainHandler::removeCallbacks)
        connectionProbeRunnable = null
        connectionProbeWatchdogRunnable?.let(mainHandler::removeCallbacks)
        connectionProbeWatchdogRunnable = null
        awaitingConnectionProbeId = null
    }

    private fun scheduleJoinAttempt(reason: String, delayMillis: Long = 0) {
        if (!answered || !mirrorReady || callEnding || joinPolicy.joined || isFinishing || isDestroyed) return
        joinRetryRunnable?.let(mainHandler::removeCallbacks)
        val runnable = Runnable { attemptJoin(reason) }
        joinRetryRunnable = runnable
        mainHandler.postDelayed(runnable, delayMillis)
    }

    private fun attemptJoin(reason: String) {
        if (!answered || callEnding || joinPolicy.joined || isFinishing || isDestroyed) return
        webView.evaluateJavascript(joinButtonScript) { result ->
            if (callEnding || isFinishing || isDestroyed) return@evaluateJavascript
            val decision = joinPolicy.record(result)
            if (diagnosticsEnabled()) {
                FaceTimeDiagnostics.record(
                    this,
                    "activity join_attempt reason=$reason attempt=${joinPolicy.attempts} outcome=${decision.outcome} joined=${decision.joined} mirrorReady=$mirrorReady answered=$answered",
                )
                Log.i(
                    diagnosticTag,
                    "join attempt reason=$reason attempt=${joinPolicy.attempts} outcome=${decision.outcome} mirrorReady=$mirrorReady answered=$answered"
                )
            }
            if (decision.joined) {
                showCallUi(joined = true)
                stopConnectionProbing()
                return@evaluateJavascript
            }
            showCallUi(joined = false)
            scheduleConnectionProbe(FaceTimeConnectionProbePolicy.initialDelayMillis)
            if (decision.retry) {
                scheduleJoinAttempt("retry-${decision.outcome}", 750)
            } else {
                showCallUi(joined = false)
                binding.connectionStatus.text = "Tap Join or Rejoin to connect"
                if (diagnosticsEnabled()) {
                    Log.w(diagnosticTag, "automatic join attempts exhausted")
                }
            }
        }
    }

    fun endCall() {
        requestTerminalEnd(FaceTimeLifecycleEndTrigger.NATIVE_END)
    }

    private fun lifecycleEndSnapshot(): FaceTimeLifecycleEndSnapshot = FaceTimeLifecycleEndSnapshot(
        activeCall = !callUuid.isNullOrBlank() || answered || joinPolicy.admissionRequested || joinPolicy.joined,
        currentActivity = activeFaceTimeActivity === this,
        changingConfigurations = isChangingConfigurations,
        inPictureInPicture = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode,
        incomingCall = notificationId != 0,
        answered = answered,
        rendererAvailable = rendererAvailable && ::webView.isInitialized,
    )

    private fun requestTerminalEnd(trigger: FaceTimeLifecycleEndTrigger) {
        val action = lifecycleEndPolicy.consume(trigger, lifecycleEndSnapshot()) ?: return
        callEnding = true
        stopConnectionProbing()
        joinRetryRunnable?.let(mainHandler::removeCallbacks)
        manualRecoveryRunnable?.let(mainHandler::removeCallbacks)
        reportLocalCallEnded()
        if (::binding.isInitialized) {
            binding.connectionStatus.text = "Ending FaceTime..."
            binding.connectionStatus.visibility = View.VISIBLE
            binding.endCall.isEnabled = false
        }

        when (action) {
            FaceTimeRemoteEndAction.WEB_LEAVE -> dispatchWebLeave()
            FaceTimeRemoteEndAction.NATIVE_DECLINE -> dispatchNativeDecline()
            FaceTimeRemoteEndAction.ALREADY_SENT -> finishTerminalActivity()
            FaceTimeRemoteEndAction.NO_SAFE_ACTION -> {
                // NativePushState exposes decline_session only. It does not
                // expose cancel_session to Kotlin, and using decline for an
                // answered/outgoing call is semantically unsafe.
                Log.w(diagnosticTag, "remote end unavailable reason=native_cancel_binding_missing")
                finishTerminalActivity()
            }
        }
    }

    private fun dispatchWebLeave() {
        val fallback = Runnable {
            if (!isFinishing && !isDestroyed) {
                if (diagnosticsEnabled()) {
                    Log.w(diagnosticTag, "web leave timeout; finishing activity")
                }
                finishAndRemoveTask()
            }
        }
        endFallbackRunnable = fallback
        mainHandler.postDelayed(fallback, 1500)
        val requested = runCatching {
            webView.evaluateJavascript(
                """(() => { const buttons = Array.from(document.querySelectorAll("button")); const label = (element) => (element?.innerText || element?.textContent || element?.getAttribute?.("aria-label") || "").trim(); const button = document.getElementById("callcontrols-leave-button-session-banner") || buttons.find((item) => /^(leave|end call)$/i.test(label(item))); if (!button) return "missing"; button.click(); return "clicked"; })()"""
            ) { result ->
                if (diagnosticsEnabled()) {
                    val clicked = result?.trim()?.removeSurrounding("\"") == "clicked"
                    Log.i(diagnosticTag, "web leave completed clicked=$clicked")
                }
                mainHandler.removeCallbacks(fallback)
                finishTerminalActivity()
            }
        }.isSuccess
        if (!requested) {
            mainHandler.removeCallbacks(fallback)
            Log.w(diagnosticTag, "web leave unavailable reason=renderer_request_failed")
            finishTerminalActivity()
        }
    }

    private fun dispatchNativeDecline() {
        val activeCallUuid = callUuid
        if (activeCallUuid.isNullOrBlank()) {
            Log.w(diagnosticTag, "native decline unavailable reason=missing_call_id")
            finishTerminalActivity()
            return
        }
        val client = APNClient(applicationContext)
        client.bind { service: APNService ->
            try {
                val pushState = service.pushState
                if (pushState == null) {
                    Log.w(diagnosticTag, "native decline unavailable reason=push_state_missing")
                } else {
                    pushState.declineFacetime(activeCallUuid)
                    if (diagnosticsEnabled()) Log.i(diagnosticTag, "native decline dispatched")
                }
            } finally {
                client.destroy()
            }
        }
        finishTerminalActivity()
    }

    private fun finishTerminalActivity() {
        endFallbackRunnable?.let(mainHandler::removeCallbacks)
        endFallbackRunnable = null
        if (!isFinishing && !isDestroyed) finishAndRemoveTask()
    }

    private fun hideControlsForPIP() {
        webView.loadUrl("javascript:if (document.querySelector(\".session-banner\").style.opacity == 1) { document.getElementById(\"canvas-layout-container\").click() }")
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            hideControlsForPIP()
        }
    }

    private fun decline() {
        // delete notification
        if (notificationId != 0) {
            DeleteNotificationHandler().deleteNotification(this, notificationId, Constants.newFaceTimeNotificationTag)
        }
        requestTerminalEnd(FaceTimeLifecycleEndTrigger.INCOMING_REJECT)
    }

    private fun invLerp(a: Int, b: Int, x: Int): Float {
        return (x - a).toFloat() / (b - a).toFloat()
    }

    private fun updateMediaVolume(audioManager: AudioManager) {
        try {
            val progress = invLerp(
                audioManager.getStreamMinVolumeCompat(AudioManager.STREAM_VOICE_CALL),
                audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL),
                audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL),
            )
            val volume = MathUtils.lerp(
                audioManager.getStreamMinVolumeCompat(AudioManager.STREAM_MUSIC).toFloat(),
                audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).toFloat(),
                progress
            ).roundToInt()
            audioManager.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                volume,
                0
            )
        } catch (e: SecurityException) {
            Log.w("FaceTime", "Unable to set stream volume!")
        }

    }

    var contentObserver: ContentObserver? = null

    private fun handlePermissionRequests() {
        cached.deferredRequestCanceled = { request ->
            permissionRequests.remove(request)
        }
        for (request in cached.deferredRequests.toList()) {
            handlePermissionRequest(request)
        }
        cached.deferredRequests.clear()
        cached.deferredRequestsUpdated = {
            for (request in cached.deferredRequests.toList()) {
                handlePermissionRequest(request)
            }
            cached.deferredRequests.clear()
        }

        // weird bug where it uses the Music stream but the default stream is set to call
        // you want it maxed. Trust me. And if you don't the UI will open so you know :)
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        initialMediaVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        updateMediaVolume(audioManager)
        val observer = object : ContentObserver(
            Handler(Looper.getMainLooper())
        ) {
            override fun deliverSelfNotifications(): Boolean {
                return false
            }

            override fun onChange(selfChange: Boolean) {
                updateMediaVolume(audioManager)
            }
        }
        applicationContext.contentResolver.registerContentObserver(android.provider.Settings.System.CONTENT_URI, true, observer)
        contentObserver = observer
    }

    private fun answerCall() {
        answered = true

        if (diagnosticsEnabled()) {
            Log.i(diagnosticTag, "answer requested mirrorReady=$mirrorReady deferredPermissions=${cached.deferredRequests.size}")
        }

        handlePermissionRequests()

        if (notificationId != 0) {
            DeleteNotificationHandler().deleteNotification(this, notificationId, Constants.newFaceTimeNotificationTag)
        }

        if (mirrorReady) {
            logJoinButtonState("answer-ready")
            scheduleJoinAttempt("answer-ready")
        } else {
            connecting()
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)

    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val launchExtras = intent.extras
        if (launchExtras == null || !hasRequiredFaceTimeLaunchData(launchExtras.getString("link"))) {
            // Android can restore the dedicated FaceTime task from Recents after
            // its process or APK has changed. That restored base intent has no
            // call metadata and cannot safely recreate the WebView session.
            Log.w(
                diagnosticTag,
                "discarding FaceTime launch without current call metadata hasExtras=${launchExtras != null}",
            )
            finishAndRemoveTask()
            return
        }

        binding = ActivityFaceTimeBinding.inflate(layoutInflater)

        // Publish the UUID before the activity becomes visible to the launch
        // handler so a duplicate event cannot slip through during startup.
        callUuid = launchExtras.getString("callUuid")
        activeFaceTimeActivity = this

        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT

        WindowCompat.setDecorFitsSystemWindows(window, false)


        // show when locked
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                        or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }

        handleConfig(launchExtras)
        binding.mainFrame.addView(webView)

        binding.accept.setOnClickListener {
            answerCall()
        }

        binding.reject.setOnClickListener {
            decline()
        }

        binding.endCall.setOnClickListener {
            endCall()
        }

        binding.retryAdmission.setOnClickListener {
            if (!manualAdmissionRetryState.begin()) return@setOnClickListener
            binding.retryAdmission.isEnabled = false
            binding.retryAdmission.text = "Retrying..."
            MethodCallHandler.invokeMethodForBooleanResult(
                "facetime-admission-retry",
                emptyMap(),
            ) { success ->
                runOnUiThread {
                    if (callEnding || isFinishing || isDestroyed) return@runOnUiThread
                    manualAdmissionRetryState.complete(success)
                    binding.retryAdmission.isEnabled = !success
                    binding.retryAdmission.text = if (success) "Retry sent" else "Retry"
                    if (!success) {
                        binding.connectionStatus.visibility = View.VISIBLE
                        binding.connectionStatus.text = "Admission retry was not sent. Try again."
                    }
                    if (diagnosticsEnabled()) {
                        FaceTimeDiagnostics.record(this, FaceTimeResolvedMediaBridge.admissionRetryDiagnostic(success))
                    }
                }
            }
        }



        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val sourceRectHint = Rect()
            webView.getGlobalVisibleRect(sourceRectHint)

            val intentWithData = Intent(
                this,
                FaceTimeActionReceiver::class.java
            )

            setPictureInPictureParams(
                PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(1, 1))
                    .setActions(listOf(
                        RemoteAction(
                            Icon.createWithResource(this, R.drawable.call_end),
                            "End Call",
                            "End this FaceTime Call",
                            PendingIntent.getBroadcast(this, 1, intentWithData,
                                PendingIntent.FLAG_IMMUTABLE)
                        )
                    ))
                    .setSourceRectHint(sourceRectHint)
                    .setAutoEnterEnabled(true)
                    .build())

            val mOnLayoutChangeListener =
                View.OnLayoutChangeListener { v: View?, oldLeft: Int,
                                              oldTop: Int, oldRight: Int, oldBottom: Int, newLeft: Int, newTop:
                                              Int, newRight: Int, newBottom: Int ->
                    val sourceRectHint = Rect()
                    webView.getGlobalVisibleRect(sourceRectHint)
                    val builder = PictureInPictureParams.Builder()
                        .setSourceRectHint(sourceRectHint)
                    setPictureInPictureParams(builder.build())
                }

            webView.addOnLayoutChangeListener(mOnLayoutChangeListener)
        }

        val view = binding.root
        setContentView(view)
    }

    var serviceStarted: Boolean = false

    fun startOrRefreshService() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val intent = Intent(this, FaceTimeInCallService::class.java).apply {
                    action = FaceTimeInCallService.ACTION_REFRESH_FOREGROUND_TYPES
                }
                startForegroundService(intent)
            }
            serviceStarted = true
        } catch (error: RuntimeException) {
            serviceStarted = false
            Log.e(diagnosticTag, "unable to start FaceTime foreground service: ${error.javaClass.simpleName}")
        }
    }

    private fun reportLocalCallEnded() {
        val endedCallUuid = localEndReporter.consume(callUuid) ?: return
        MethodCallHandler.invokeMethodOrWorker(
            applicationContext,
            "facetime-call-ended",
            mapOf("callUuid" to endedCallUuid),
        )
    }

    fun handlePermissionRequest(request: PermissionRequest) {
        val recognizedResources = request.resources.filter(permissionMap::containsKey)
        if (recognizedResources.isEmpty() || recognizedResources.size != request.resources.size) {
            Log.w(diagnosticTag, "denying unsupported WebView permission resources=${request.resources.sorted().joinToString()}")
            request.deny()
            return
        }
        if (!permissionRequests.contains(request)) {
            permissionRequests.add(request)
        }
        processPermissionRequests()
    }

    private fun processPermissionRequests() {
        val grantedPermissions = permissionMap.values.flatten().filterTo(mutableSetOf()) {
            checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
        var grantedAnyResource = false
        val iterator = permissionRequests.iterator()
        while (iterator.hasNext()) {
            val request = iterator.next()
            val recognizedResources = request.resources.filter(permissionMap::containsKey)
            val requiredPermissions = recognizedResources
                .flatMap { permissionMap[it] ?: emptyList() }
                .toSet()
            when (faceTimePermissionDecision(requiredPermissions, grantedPermissions, deniedAndroidPermissions)) {
                FaceTimePermissionDecision.GRANT -> {
                    val grantSucceeded = runCatching { request.grant(recognizedResources.toTypedArray()) }
                        .onFailure { Log.w(diagnosticTag, "WebView permission grant was canceled") }
                        .isSuccess
                    iterator.remove()
                    grantedAnyResource = grantedAnyResource || grantSucceeded
                }
                FaceTimePermissionDecision.DENY -> {
                    runCatching { request.deny() }
                    iterator.remove()
                }
                FaceTimePermissionDecision.WAIT -> Unit
            }
        }
        // A later microphone or camera grant must upgrade the running
        // foreground-service type, not merely start the service once.
        if (grantedAnyResource) startOrRefreshService()
        if (permissionRequestInFlight || permissionRequests.isEmpty()) return

        val missingPermissions = permissionRequests
            .flatMap { request -> request.resources.flatMap { permissionMap[it] ?: emptyList() } }
            .filter { it !in grantedPermissions && it !in deniedAndroidPermissions }
            .distinct()
        if (missingPermissions.isEmpty()) {
            permissionRequests.toList().forEach { runCatching { it.deny() } }
            permissionRequests.clear()
            return
        }
        permissionRequestInFlight = true
        try {
            requestPermissions(missingPermissions.toTypedArray(), 1)
        } catch (error: RuntimeException) {
            permissionRequestInFlight = false
            deniedAndroidPermissions.addAll(missingPermissions)
            Log.e(diagnosticTag, "unable to request FaceTime media permissions: ${error.javaClass.simpleName}")
            processPermissionRequests()
        }
    }

    override fun onDestroy() {
        // onStop handles normal task removal first. This is the final safety
        // net for renderer-independent or otherwise unexpected destruction.
        requestTerminalEnd(FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY)
        joinRetryRunnable?.let(mainHandler::removeCallbacks)
        manualRecoveryRunnable?.let(mainHandler::removeCallbacks)
        stopConnectionProbing()
        endFallbackRunnable?.let(mainHandler::removeCallbacks)
        permissionRequests.toList().forEach { runCatching { it.deny() } }
        permissionRequests.clear()
        permissionRequestInFlight = false
        if (::cached.isInitialized) {
            cached.cancelCallbacks()
        }

        val isCurrentActivity = activeFaceTimeActivity === this
        if (isCurrentActivity) {
            activeFaceTimeActivity = null
            val preservingCall = isChangingConfigurations ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode)
            if (!preservingCall) {
                val intent = Intent(this, FaceTimeInCallService::class.java)
                stopService(intent)
                serviceStarted = false

                // An older FaceTime activity must not mute or reroute a newer call.
                initialMediaVolume?.let {
                    try {
                        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
                        audioManager.setStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            it,
                            0
                        )
                    } catch (e: SecurityException) {
                        Log.w("FaceTime", "Unable to set stream volume!")
                    }
                }
            }
        }

        if (::webView.isInitialized) webView.destroy()

        contentObserver?.let {
            applicationContext.contentResolver.unregisterContentObserver(it)
        }

        super.onDestroy()
    }

    override fun onStop() {
        // A removed task reaches onStop while finishing. Back/native end have
        // already consumed the same one-shot policy; PiP/config transitions do
        // not qualify and therefore cannot emit a remote side effect.
        if (isFinishing) {
            requestTerminalEnd(FaceTimeLifecycleEndTrigger.TASK_REMOVAL)
        }
        super.onStop()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (callEnding) {
            super.onBackPressed()
        } else {
            requestTerminalEnd(FaceTimeLifecycleEndTrigger.BACK)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode != 1) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (diagnosticsEnabled()) {
            Log.i(
                diagnosticTag,
                "Android permission result ${permissions.zip(grantResults.toTypedArray()).joinToString { (permission, result) -> "$permission=${result == PackageManager.PERMISSION_GRANTED}" }}"
            )
        }
        permissions.forEachIndexed { index, permission ->
            if (index < grantResults.size && grantResults[index] == PackageManager.PERMISSION_GRANTED) {
                deniedAndroidPermissions.remove(permission)
            } else {
                deniedAndroidPermissions.add(permission)
            }
        }
        permissionRequestInFlight = false
        processPermissionRequests()
    }

    private fun connecting() {
        if (diagnosticsEnabled()) {
            Log.i(diagnosticTag, "waiting for mirrorReady")
        }
        binding.acceptButtons.visibility = View.GONE
        binding.nativeCallControls.visibility = View.VISIBLE
        binding.endCall.isEnabled = true
        binding.loadingBanner.text = "Connecting..."
        val recoveryRunnable = Runnable {
            if (callEnding || isFinishing || isDestroyed || joinPolicy.joined) return@Runnable
            if (diagnosticsEnabled()) {
                Log.w(diagnosticTag, "mirrorReady timeout reached mirrorReady=$mirrorReady answered=$answered")
            }
            logJoinButtonState("mirror-timeout")
            showCallUi(joined = false)
        }
        manualRecoveryRunnable = recoveryRunnable
        mainHandler.postDelayed(recoveryRunnable, 15000)
    }

    /** Shows the one-shot recovery action after an ambiguous admission send. */
    fun showAdmissionRecovery() {
        if (callEnding || isFinishing || isDestroyed) return
        binding.nativeCallControls.visibility = View.VISIBLE
        binding.retryAdmission.visibility = View.VISIBLE
        binding.retryAdmission.isEnabled = !manualAdmissionRetryState.inFlight && !manualAdmissionRetryState.succeeded
        binding.retryAdmission.text = if (manualAdmissionRetryState.succeeded) "Retry sent" else "Retry"
        binding.connectionStatus.visibility = View.VISIBLE
        binding.connectionStatus.text = "Admission timed out. Retry once if needed."
    }

    private fun handleConfig(extras: Bundle) {
        val link = extras.getString("link")?.takeIf(::hasRequiredFaceTimeLaunchData)
        if (link == null) {
            Log.w(diagnosticTag, "missing FaceTime link while configuring activity")
            finishAndRemoveTask()
            return
        }
        val name = extras.getString("name")
        val requestedCallUuid = extras.getString("callUuid")
        callUuid = requestedCallUuid
        // sanitize desc
        val desc = extras.getString("desc")?.replace("[^a-zA-Z0-9, +.@:&]+".toRegex(), "") ?: "FaceTime Call"
        if (cachedWebview != null && cachedCallUuid == requestedCallUuid) {
            // take control of a pre-rendered webview
            cached = cachedWebview!!
            cachedWebview = null
            cachedCallUuid = null
        } else {
            cachedWebview?.let { stale ->
                stale.cancelCallbacks()
                stale.webView.destroy()
            }
            cachedWebview = null
            cachedCallUuid = null
            cached = CachedWebview(this, name, desc, link)
        }

        rendererAvailable = true
        cached.endTask = { reason ->
            when (reason) {
                FaceTimeWebEndReason.EXPLICIT_LEAVE -> {
                    requestTerminalEnd(FaceTimeLifecycleEndTrigger.EXPLICIT_WEB_LEAVE)
                }
                FaceTimeWebEndReason.RENDERER_GONE -> {
                    rendererAvailable = false
                    requestTerminalEnd(FaceTimeLifecycleEndTrigger.RENDERER_GONE)
                }
            }
        }
        cached.mediaEvidenceCall = ::onResolvedMediaEvidence
        mirrorReady = cached.mirrorReady
        cached.mirrorReadyCall = {
            mirrorReady = true
            if (diagnosticsEnabled()) {
                Log.i(diagnosticTag, "mirrorReady callback answered=$answered")
            }
            if (answered) {
                logJoinButtonState("mirror-ready")
                scheduleJoinAttempt("mirror-ready")
            }
        }

        webView = cached.webView

        val isAnsweringCall = extras.containsKey("answer")
        notificationId = extras.getString("notificationId")?.toInt() ?: 0

        if (CreateIncomingFaceTimeNotification.avatarCache.containsKey(callUuid)) {
            val bitmap = CreateIncomingFaceTimeNotification.avatarCache.remove(callUuid)!!
            binding.avatarView.setImageBitmap(bitmap)
        }

        if (diagnosticsEnabled()) {
            FaceTimeDiagnostics.record(
                this,
                "activity started hasCallUuid=${callUuid != null} answering=$isAnsweringCall",
            )
            Log.i(diagnosticTag, "started activity hasCallUuid=${callUuid != null} answering=$isAnsweringCall")
        }

        val poster = extras.getString("poster")
        if (poster != null) {
            binding.posterView.setImageBitmap(BitmapFactory.decodeFile(poster))
            binding.callDescription.visibility = View.GONE
            // no background blur because we are occluded
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                window.setBackgroundBlurRadius(0)
            }
        } else {
            binding.posterView.visibility = View.GONE
        }

        if (isAnsweringCall) {
            isCall = true
            binding.callTitle.text = desc
            binding.splashLayout.visibility = View.VISIBLE
            if (extras.getBoolean("answer")) {
                answerCall()
            }
        } else {
            binding.splashLayout.visibility = View.GONE
            binding.mainFrame.visibility = View.VISIBLE
            binding.nativeCallControls.visibility = View.VISIBLE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                window.setBackgroundBlurRadius(0)
            }
            handlePermissionRequests()
        }
    }
}
