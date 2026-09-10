package com.bluebubbles.messaging.services.backend_ui_interop

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/** Completes Dart's startup request before allowing native work to enter Dart. */
internal class DartWorkerReadyHandler(
    private val onReady: () -> Unit,
    private val forward: MethodChannel.MethodCallHandler,
) : MethodChannel.MethodCallHandler {
    private val readyDelivered = AtomicBoolean(false)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "ready") {
            forward.onMethodCall(call, result)
            return
        }

        // Each request needs its own reply, including duplicate ready calls.
        // Dart awaits this reply before completing its headless service graph.
        result.success(null)
        if (readyDelivered.compareAndSet(false, true)) onReady()
    }
}
