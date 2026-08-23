package com.bluebubbles.messaging.services.system

import android.content.Context
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

class NativeSyncIsolateHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "native-sync-isolate"

        var engine: FlutterEngine? = null
    }

    override fun handleMethodCall(
        call: MethodCall,
        mainresult: MethodChannel.Result,
        mainContext: Context
    ) {
        val context = mainContext.applicationContext

        var param = call.argument<Boolean>("close") ?: false
        if (param) {
            engine?.destroy()
            engine = null
            mainresult.success(null)
            return
        }

        if (engine != null) {
            mainresult.success(null)
            return
        }

        val workerEngine = FlutterEngine(context)
        val startResultCompleted = AtomicBoolean(false)
        engine = workerEngine
        workerEngine.addEngineLifecycleListener(
            object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() = Unit

                override fun onEngineWillDestroy() {
                    if (engine === workerEngine) {
                        engine = null
                    }
                }
            }
        )
        try {
            val flutterLoader = FlutterInjector.instance().flutterLoader()
            flutterLoader.startInitialization(context)
            flutterLoader.ensureInitializationComplete(context, null)
            val appBundlePath = flutterLoader.findAppBundlePath()

            Log.d(Constants.logTag, "Loading callback info")
            MethodChannel(workerEngine.dartExecutor.binaryMessenger, Constants.methodChannel).setMethodCallHandler {
                    call, result -> run {
                if (call.method == "ready") {
                    Log.d(Constants.logTag, "Dart engine is ready!")
                    if (startResultCompleted.compareAndSet(false, true)) {
                        mainresult.success(null)
                    }
                    result.success(null)
                } else if (call.method == "exit") {
                    result.success(null)
                    if (engine === workerEngine) {
                        engine = null
                    }
                    workerEngine.destroy()
                } else {
                    MethodCallHandler().methodCallHandler(call, result, context)
                }
            }
            }
            val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(
                context.getSharedPreferences("FlutterSharedPreferences", 0)
                    .getLong("flutter.backgroundSyncIsolate", -1)
            ) ?: throw IllegalStateException("CloudKit sync callback is unavailable")
            val callback = DartExecutor.DartCallback(context.assets, appBundlePath, callbackInfo)

            Log.d(Constants.logTag, "Executing Dart callback")
            workerEngine.dartExecutor.executeDartCallback(callback)
        } catch (error: Throwable) {
            Log.e(Constants.logTag, "Unable to start CloudKit sync isolate", error)
            if (engine === workerEngine) {
                engine = null
            }
            workerEngine.destroy()
            if (startResultCompleted.compareAndSet(false, true)) {
                mainresult.error(
                    "sync_isolate_start_failed",
                    error.message ?: error.javaClass.simpleName,
                    null,
                )
            }
        }
    }
}
