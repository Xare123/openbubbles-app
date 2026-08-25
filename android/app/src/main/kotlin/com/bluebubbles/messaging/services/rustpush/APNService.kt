package com.bluebubbles.messaging.services.rustpush

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSuggestion
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.ContactsContract
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorkManager
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorker
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.bluebubbles.messaging.services.system.GetZenMode
import com.bluebubbles.messaging.services.system.ZenModeUUIDHandler
import com.bluebubbles.telephony_plus.receive.SMSObserver
import com.google.gson.GsonBuilder
import com.google.gson.ToNumberPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import uniffi.rust_lib_bluebubbles.HandleWifiNetworksCallback
import uniffi.rust_lib_bluebubbles.NativePushState
import uniffi.rust_lib_bluebubbles.initNative
import uniffi.rust_lib_bluebubbles.MsgReceiver
import uniffi.rust_lib_bluebubbles.setupKeystore
import uniffi.rust_lib_bluebubbles.start

class APNService : Service(), MsgReceiver {
    companion object {
        private const val RECEIVE_LOG_TAG = "RustPushReceive"
        private const val MAX_PENDING_ENGINE_DISPATCHES = 256

        @Volatile
        private var activeService: APNService? = null

        fun onMainEngineReady() {
            activeService?.flushPendingMainEngineDispatches()
        }

        fun onMainEngineUnavailable() {
            activeService?.handoffPendingMainEngineDispatches()
        }
    }

    var pushState: NativePushState? = null
    private var started = false
    private val binder = APNBinder()
    private var ready = false
    private val waitingHandleCb = ArrayList<(handle: ULong) -> Unit>()
    private val waitingStartedCb = ArrayList<() -> Unit>()
    private val pendingMainEngineDispatches =
        PendingApnDispatchQueue(MAX_PENDING_ENGINE_DISPATCHES)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var smsObserver: SMSObserver? = null
    private val job = SupervisorJob()
    val scope = CoroutineScope(Dispatchers.IO + job)

    override fun onCreate() {
        super.onCreate()
        activeService = this
    }

    fun ready() {
        Log.i("launching agent", "ready")
        synchronized(waitingHandleCb) {
            ready = true
            for (cb in waitingHandleCb) {
                cb(pushState?.getState() ?: 0UL)
            }
            waitingHandleCb.clear()
        }
    }

    fun whenStarted(cb: () -> Unit) {
        var runNow = false
        synchronized(waitingStartedCb) {
            if (started) {
                runNow = true
            } else {
                waitingStartedCb.add(cb)
            }
        }
        if (runNow) {
            cb()
        }
    }

    private fun markStarted() {
        val callbacks = ArrayList<() -> Unit>()
        synchronized(waitingStartedCb) {
            if (started) return
            started = true
            callbacks.addAll(waitingStartedCb)
            waitingStartedCb.clear()
        }
        callbacks.forEach { it() }
    }

    override fun twofaEvent(success: Boolean) {
        AppleAccountLoginHandler.activity?.handleLoginSuccess(success)
        Log.i("TwoFa event", success.toString())
    }

    override fun receievedMsg(ptr: ULong, retry: ULong) {
        mainHandler.post {
            if (MainActivity.engine != null && MainActivity.engine_ready) {
                dispatchToMainEngine(PendingApnDispatch(ptr, retry))
                return@post
            }

            if (MainActivity.engine != null) {
                val result = pendingMainEngineDispatches.enqueue(ptr, retry)
                when {
                    result.evicted -> Log.w(
                        RECEIVE_LOG_TAG,
                        "engine_buffer_evicted retry=$retry pending_count=${result.size}",
                    )
                    result.added -> Log.i(
                        RECEIVE_LOG_TAG,
                        "engine_buffered retry=$retry pending_count=${result.size}",
                    )
                    else -> Log.d(
                        RECEIVE_LOG_TAG,
                        "engine_buffer_coalesced retry=$retry pending_count=${result.size}",
                    )
                }
                return@post
            }

            dispatchToHeadless(
                listOf(PendingApnDispatch(ptr, retry)),
                reason = "no_main_engine",
            )
        }
    }

    private fun dispatchToMainEngine(dispatch: PendingApnDispatch) {
        MethodCallHandler.invokeMethod(
            "APNMsg",
            mapOf(
                "pointer" to dispatch.pointer.toString(),
                "retry" to dispatch.retry.toString(),
            ),
        )
    }

    private fun flushPendingMainEngineDispatches() {
        runOnMainThread {
            if (MainActivity.engine == null || !MainActivity.engine_ready) {
                return@runOnMainThread
            }

            val dispatches = pendingMainEngineDispatches.drain()
            if (dispatches.isEmpty()) {
                return@runOnMainThread
            }

            Log.i(
                RECEIVE_LOG_TAG,
                "engine_buffer_flush count=${dispatches.size}",
            )
            for (dispatch in dispatches) {
                dispatchToMainEngine(dispatch)
            }
        }
    }

    private fun handoffPendingMainEngineDispatches() {
        runOnMainThread {
            if (MainActivity.engine != null) {
                if (MainActivity.engine_ready) {
                    flushPendingMainEngineDispatches()
                }
                return@runOnMainThread
            }

            val dispatches = pendingMainEngineDispatches.drain()
            dispatchToHeadless(dispatches, reason = "main_engine_unavailable")
        }
    }

    private fun dispatchToHeadless(
        dispatches: List<PendingApnDispatch>,
        reason: String,
    ) {
        if (dispatches.isEmpty()) {
            return
        }

        Log.i(
            RECEIVE_LOG_TAG,
            "headless_handoff reason=$reason count=${dispatches.size}",
        )
        CoroutineScope(Dispatchers.Main).launch {
            for (dispatch in dispatches) {
                Log.d(RECEIVE_LOG_TAG, "headless_dispatch retry=${dispatch.retry}")
                try {
                    DartWorker.callMethod(
                        this@APNService,
                        "APNMsg",
                        mapOf(
                            "pointer" to dispatch.pointer.toString(),
                            "retry" to dispatch.retry.toString(),
                        ),
                    )
                } catch (error: Exception) {
                    Log.w(
                        RECEIVE_LOG_TAG,
                        "headless_dispatch_failed retry=${dispatch.retry} error=${error.javaClass.simpleName}",
                    )
                }
            }
        }
    }

    private inline fun runOnMainThread(crossinline block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post { block() }
        }
    }

    fun configured() {
        pushState?.startLoop(this)
    }

    fun getHandle(cb: (handle: ULong) -> Unit) {
        Log.i("launching agent", "getting handle")
        synchronized(waitingHandleCb) {
            if (ready) {
                cb(pushState?.getState() ?: 0UL)
            } else {
                Log.i("launching agent", "stalled")
                waitingHandleCb.add(cb)
            }
        }
    }

    override fun nativeReady(state: NativePushState?) {
        pushState?.destroy()
        pushState = state
        state?.startLoop(this)
        ready()
    }

    // called on state destroy
    override fun finish() {
        pushState?.destroy()
        pushState = null
        Log.i("nativestate", "destroyed")
    }

    @RequiresApi(Build.VERSION_CODES.R)
    fun updateZenMode() {
        val zenMode = GetZenMode.getZenMode(this)

        Log.i("OpenBubbles", "ZenModeChanged $zenMode")
        val uuid = zenMode?.let { ZenModeUUIDHandler.getZenKey(this, it) }
        pushState?.publishStatus(uuid)
    }

    val keystore = AndroidNativeKeystore(this)

    fun launchAgent() {
        Log.i("launching agent", "herer")
        if (smsObserver == null) {
            smsObserver = SMSObserver.init(applicationContext) { _, map ->
                if (MainActivity.engine != null && MainActivity.engine_ready) {
                    // app is alive, deliver directly there
                    MethodCallHandler.invokeMethod("SMSMsg", map)
                    return@init
                }
                CoroutineScope(Dispatchers.Main).launch {
                    DartWorker.callMethod(this@APNService, "SMSMsg", map)
                }
            }
        } else {
            Log.d("SMSObserver", "SMS observer already registered")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val filter = IntentFilter(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
                filter.addAction(NotificationManager.ACTION_CONSOLIDATED_NOTIFICATION_POLICY_CHANGED)
            }
            val myHandler = Handler(Looper.getMainLooper())
            ContextCompat.registerReceiver(
                this, object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) {
                        if (!ZenModeUUIDHandler.isZenEnabled(this@APNService)) return
                        myHandler.removeCallbacksAndMessages(null)
                        myHandler.postDelayed({
                            updateZenMode()
                        }, 100)
                    }

                }, filter, ContextCompat.RECEIVER_EXPORTED
            )
        }

        Log.i("here", "hjeal")

        start(applicationContext.filesDir.path, AndroidFilePackager(this), object : HandleWifiNetworksCallback {
            @RequiresApi(Build.VERSION_CODES.Q)
            fun addWifiNetworks(networks: Map<String, String>) {
                val manager = getSystemService(WIFI_SERVICE) as WifiManager
                val suggestions = networks.entries.flatMap {
                    if (it.value.length > 63 || it.key.length > 32 || it.value.length < 8) {
                        Log.i("NETWORK", "Bad password or ssid ${it.key}")
                        return@flatMap emptyList()
                    }
                    listOf(
                        WifiNetworkSuggestion.Builder()
                            .setSsid(it.key)
                            .setWpa2Passphrase(it.value)
                            .build(),
                        WifiNetworkSuggestion.Builder()
                            .setSsid(it.key)
                            .setWpa3Passphrase(it.value)
                            .build()
                    )
                }.toList()
                val status = manager.addNetworkSuggestions(suggestions)
                if (status != WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) {
                    Log.e("NETWORK", "Adding suggestions failed! $status")
                } else {
                    Log.i("NETWORK", "Adding suggestions success!")
                }
            }

            override fun handleWifiNetworks(networks: Map<String, String>, userApprove: Boolean) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return

                if (userApprove) {
                    addWifiNetworks(networks)
                    return
                }

                val manager = getSystemService(WIFI_SERVICE) as WifiManager

                val listener = object : WifiManager.SuggestionUserApprovalStatusListener {
                    override fun onUserApprovalStatusChange(status: Int) {
                        Log.i("NETWORK", "User approval status retrived: $status")
                        if (status == WifiManager.STATUS_SUGGESTION_APPROVAL_APPROVED_BY_USER) {
                            addWifiNetworks(networks)
                        }
                        manager.removeSuggestionUserApprovalStatusListener(this)
                    }
                }

                manager.addSuggestionUserApprovalStatusListener(mainExecutor, listener)
            }
        })
        setupKeystore(applicationContext.filesDir.path, keystore)
        keystore.checkMaster()
        Log.i("here", "hjealme")

        Log.i("here", "hwallow")
        initNative(applicationContext.filesDir.path, null, this)
    }

    fun kickstartNative(handle: String) {
        initNative(applicationContext.filesDir.path, handle, this)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    fun createNotificationChannel() {
        val importance = NotificationManager.IMPORTANCE_HIGH
        val channel = NotificationChannel(FOREGROUND_SERVICE_CHANNEL, "Foreground Service", importance).apply {
            description = "Allows BlueBubbles to stay open in the background for notifications if FCM is not being used"
        }
        // Register the channel with the system
        val notificationManager: NotificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.createNotificationChannel(channel)
    }

    val FOREGROUND_SERVICE_CHANNEL = "com.bluebubbles.foreground_service";
    @RequiresApi(Build.VERSION_CODES.O)
    fun notifyForeground() {
        createNotificationChannel()
        val text = "Hold and turn off notifications to hide this notification"
        val notification: Notification = Notification.Builder(this, FOREGROUND_SERVICE_CHANNEL)
            .setContentTitle("Ready for messages")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_stat_icon)
            .setStyle(Notification.BigTextStyle()
                .bigText(text))
            .build()

        // Notification ID cannot be 0.
        startForeground(3884785, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!started) {
            Log.i("launching agent", "start commanded")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                notifyForeground()
            }
            launchAgent()
            markStarted()
        }
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onDestroy() {
        smsObserver?.close()
        smsObserver = null
        if (activeService === this) {
            activeService = null
        }
        val discarded = pendingMainEngineDispatches.clear()
        if (discarded > 0) {
            Log.i(
                RECEIVE_LOG_TAG,
                "engine_buffer_cleared_on_service_destroy count=$discarded",
            )
        }
        super.onDestroy()
        pushState?.destroy()
        job.cancel()
    }

    override fun onBind(intent: Intent): IBinder {
        Log.i("trybindsfsf", "bound")
        return binder
    }

    inner class APNBinder : Binder() {
        fun getService(): APNService = this@APNService
    }
}

class APNClient(val context: Context) {
    private lateinit var mService: APNService
    private var mBound: Boolean = false
    private var mBinding: Boolean = false
    private var mCallback: ((service: APNService) -> Unit)? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(className: ComponentName, service: IBinder) {
            // We've bound to LocalService, cast the IBinder and get LocalService instance.
            val binder = service as APNService.APNBinder
            mService = binder.getService()
            mService.whenStarted {
                if (mBound) return@whenStarted
                mBound = true
                mBinding = false
                mCallback?.let { it(mService) }
            }
        }

        override fun onServiceDisconnected(arg0: ComponentName) {
            mBound = false
            mBinding = false
        }
    }

    fun getService(): APNService {
        return mService
    }

    fun bind(cb: (service: APNService) -> Unit) {
        mCallback = cb
        if (mBound) {
            mService.whenStarted {
                mCallback?.let { it(mService) }
            }
            return
        }
        if (mBinding) return

        val serviceIntent = Intent(context, APNService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }

        Intent(context, APNService::class.java).also { intent ->
            Log.i("trybindsfsf", "trying to bind")
            mBinding = true
            val result = context.bindService(intent, connection, 0)
            if (!result) {
                mBinding = false
            }
            Log.i("trybindresult", result.toString())
        }
    }

    fun destroy() {
        if (mBound || mBinding) {
            context.unbindService(connection)
        }
        mBound = false
        mBinding = false
    }
}
