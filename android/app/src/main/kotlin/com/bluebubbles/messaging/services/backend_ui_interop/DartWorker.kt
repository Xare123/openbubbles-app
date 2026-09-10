package com.bluebubbles.messaging.services.backend_ui_interop

import android.content.Context
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.ForegroundInfo
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.MainActivity.Companion.engine
import com.bluebubbles.messaging.R
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.gson.GsonBuilder
import com.google.gson.ToNumberPolicy
import com.google.gson.reflect.TypeToken
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.guava.future
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.suspendCancellableCoroutine

class DartWorker(context: Context, workerParams: WorkerParameters): ListenableWorker(context, workerParams) {

    companion object {
        private const val RESULT_ENGINE_READY_TIMEOUT_MILLIS = 60_000L
        var workerEngine: FlutterEngine? = null
        var engineReady = Mutex()
        private val engineLifetime = DartWorkerEngineLifetime<FlutterEngine>(
            currentWorker = { workerEngine },
            scheduleIdleCheck = { check ->
                CoroutineScope(Dispatchers.Main.immediate).launch {
                    delay(30_000L)
                    check()
                }
            },
            destroyWorker = { idleEngine ->
                Log.d(Constants.logTag, "Closing ${Constants.dartWorkerTag} engine")
                workerEngine = null
                idleEngine.destroy()
            },
        )
        /// Code idea taken from https://github.com/flutter/flutter/wiki/Experimental:-Reuse-FlutterEngine-across-screens
        private suspend fun initNewEngine(applicationContext: Context) {
            Log.d(Constants.logTag, "Ensuring Flutter is initialized before creating engine")
            val flutterLoader = FlutterInjector.instance().flutterLoader()
            flutterLoader.startInitialization(applicationContext)
            flutterLoader.ensureInitializationComplete(applicationContext, null)
            val appBundlePath = flutterLoader.findAppBundlePath()

            Log.d(Constants.logTag, "Loading callback info")
            val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(
                applicationContext.getSharedPreferences("FlutterSharedPreferences", 0)
                    .getLong("flutter.backgroundCallbackHandle", -1)
            ) ?: throw IllegalStateException("worker_callback_unavailable")
            val initializingEngine = FlutterEngine(applicationContext)
            workerEngine = initializingEngine
            var startupCompleted = false
            try {
                initializingEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                    override fun onPreEngineRestart() {
                        Log.d(Constants.logTag, "Engine is restarting")
                    }

                    override fun onEngineWillDestroy() {
                        Log.d(Constants.logTag, "Engine is being destroyed")
                    }
                })
                suspendCancellableCoroutine<Unit> { cont ->
                    // Set up the method channel to receive events from Dart.
                    MethodChannel(initializingEngine.dartExecutor.binaryMessenger, Constants.methodChannel)
                        .setMethodCallHandler(DartWorkerReadyHandler(
                            onReady = {
                                Log.d(Constants.logTag, "Dart engine is ready!")
                                if (cont.isActive) cont.resume(Unit)
                            },
                            forward = { call, result ->
                                MethodCallHandler().methodCallHandler(call, result, applicationContext)
                            },
                        ))
                    val callback = DartExecutor.DartCallback(applicationContext.assets, appBundlePath, callbackInfo)

                    Log.d(Constants.logTag, "Executing Dart callback")
                    initializingEngine.dartExecutor.executeDartCallback(callback)
                }
                startupCompleted = true
            } finally {
                // Also covers cancellation after ready resumed but before this
                // coroutine reacquired execution, and synchronous startup failure.
                if (!startupCompleted && workerEngine === initializingEngine) {
                    workerEngine = null
                    initializingEngine.destroy()
                }
            }
        }

        suspend fun callMethod(
            applicationContext: Context,
            method: String,
            arguments: Map<String, Any>,
        ): Unit = withContext(Dispatchers.Main.immediate) {
            engineReady.withLock {
                if (engine == null && workerEngine == null) {
                    Log.d(Constants.logTag, "Initializing engine for worker with method $method")
                    initNewEngine(applicationContext)
                }
            }
            Log.d(Constants.logTag, "Sending event, '$method' to Dart")

            try {
                val engineToUse: FlutterEngine? = engine ?: workerEngine
                if (engineToUse == null) {
                    Log.d(Constants.logTag, "Engine is null, cannot send method $method to Dart")
                    throw Exception("No engine")
                }

                Log.d(Constants.logTag, "Invoking method channel...")
                val release = engineLifetime.acquire(engineToUse)
                suspendCoroutine { cont ->
                    val finished = AtomicBoolean(false)
                    fun finish(result: kotlin.Result<Result>) {
                        if (!finished.compareAndSet(false, true)) return
                        try { cont.resumeWith(result) } finally { release() }
                    }
                    try {
                      MethodChannel(engineToUse.dartExecutor.binaryMessenger, Constants.methodChannel).invokeMethod(method, arguments, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            Log.d(Constants.logTag, "Worker with method $method completed successfully")
                            finish(kotlin.Result.success(Result.success()))
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            Log.e(Constants.logTag, "Worker with method $method failed!")
                            finish(kotlin.Result.success(Result.failure()))
                        }

                        override fun notImplemented() {
                            Log.e(Constants.logTag, "Worker with method $method not implemented on Dart side")
                            finish(kotlin.Result.success(Result.failure()))
                        }
                      })
                    } catch (error: Throwable) {
                        finish(kotlin.Result.failure(error))
                    }
                }

                Log.d(Constants.logTag, "Worker with method $method completed successfully")
            } catch (e: Exception) {
                Log.d(Constants.logTag, "Error sending method $method to Dart: ${e.message}")
                throw e
            }
        }

        /**
         * Result-bearing method-channel call used only by bounded workers that
         * need an explicit Dart disposition. Existing fire-and-forget callers
         * retain [callMethod]'s behavior.
         */
        suspend fun callMethodForOutcome(
            applicationContext: Context,
            method: String,
            arguments: Map<String, Any>,
        ): String = withContext(Dispatchers.Main.immediate) {
            engineReady.withLock {
                if (engine != null && !MainActivity.engine_ready) {
                    throw IllegalStateException("main_engine_not_ready")
                }
                if (engine == null && workerEngine == null) {
                    Log.d(Constants.logTag, "Initializing engine for result-bearing worker")
                    withTimeout(RESULT_ENGINE_READY_TIMEOUT_MILLIS) {
                        initNewEngine(applicationContext)
                    }
                }
            }
            val engineToUse = if (engine != null && MainActivity.engine_ready) {
                engine
            } else {
                workerEngine
            } ?: throw IllegalStateException("worker_engine_unavailable")

            val release = engineLifetime.acquire(engineToUse)
            DartWorkerOutcomeCall.awaitOutcome(
                invoke = { result ->
                    MethodChannel(engineToUse.dartExecutor.binaryMessenger, Constants.methodChannel)
                        .invokeMethod(method, arguments, result)
                },
                releaseEngine = release,
            )
        }
    }

    override fun startWork(): ListenableFuture<Result> {
        val method = inputData.getString("method")!!
        var data = inputData.getString("data")!!
        val gson = GsonBuilder()
                .setObjectToNumberStrategy(ToNumberPolicy.LONG_OR_DOUBLE)
                .create()
        if (method == "SMSMsg") {
            val json: HashMap<String, Any> = gson.fromJson(data, TypeToken.getParameterized(HashMap::class.java, String::class.java, Any::class.java).type)
            val pointer: Int = (json["id"] as Long).toInt()
            if (MethodCallHandler.queuedMessages.contains(pointer)) {
                data = MethodCallHandler.queuedMessages.remove(pointer)!!
            } else {
                // bail
                return Futures.immediateFuture(Result.success())
            }
        }

        if (engine != null) {
            Log.d(Constants.logTag, "Using MainActivity engine to send to Dart")
        } else {
            Log.d(Constants.logTag, "Using DartWorker engine to send to Dart")
        }
        return CoroutineScope(Dispatchers.Main).future {
            val arguments: HashMap<String, Any> = gson.fromJson(data, TypeToken.getParameterized(HashMap::class.java, String::class.java, Any::class.java).type)
            try {
                callMethod(applicationContext, method, arguments)
                Result.success()
            } catch (e: Exception) {
                Log.d(Constants.logTag, "Error sending method $method to Dart: ${e.message}")
                Result.failure()
            }
        }
    }

    // Dumb thing that appears to be necessary for Android 11 and under (see https://stackoverflow.com/questions/69684656/upgrading-to-workmanager-2-7-0-how-to-implement-getforegroundinfoasync-for-rxwo)
    override fun getForegroundInfoAsync(): ListenableFuture<ForegroundInfo> {
        val notification = NotificationCompat.Builder(applicationContext, "com.bluebubbles.foreground_service")
            .setSmallIcon(R.mipmap.ic_stat_icon)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentTitle("BlueBubbles DartWorker")
            .setContentText("BlueBubbles is performing short work in the background")
            .setColor(4888294)
            .build()
        return Futures.immediateFuture(ForegroundInfo(Constants.dartWorkerNotificationId, notification))
    }
}
