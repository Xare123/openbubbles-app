package com.bluebubbles.messaging.services.backend_ui_interop

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class DartWorkerReadyHandlerTest {
    @Test
    fun `Dart receives its ready reply before native work resumes`() {
        val events = mutableListOf<String>()
        val handler = DartWorkerReadyHandler(
            onReady = { events.add("dispatch") },
            forward = { _, _ -> error("ready must not be forwarded") },
        )

        handler.onMethodCall(MethodCall("ready", null), result {
            assertNull(it)
            events.add("acknowledged")
        })

        assertEquals(listOf("acknowledged", "dispatch"), events)
    }

    @Test
    fun `duplicate ready requests all complete without repeating startup`() {
        var acknowledgements = 0
        var starts = 0
        val handler = DartWorkerReadyHandler(
            onReady = { starts++ },
            forward = { _, _ -> error("ready must not be forwarded") },
        )
        repeat(3) {
            handler.onMethodCall(MethodCall("ready", null), result {
                acknowledgements++
            })
        }
        assertEquals(3, acknowledgements)
        assertEquals(1, starts)
    }

    @Test
    fun `service initialization calls retain their original arguments and reply`() {
        val call = MethodCall("get-native-handle", mapOf("test" to 1))
        var returned: Any? = null
        val reply = result { returned = it }
        val handler = DartWorkerReadyHandler(
            onReady = { error("ordinary calls must not signal ready") },
            forward = { actualCall, actualReply ->
                assertSame(call, actualCall)
                assertSame(reply, actualReply)
                actualReply.success(42L)
            },
        )
        handler.onMethodCall(call, reply)
        assertEquals(42L, returned)
    }

    @Test
    fun `replacement engines have an independent startup handshake`() {
        var starts = 0
        repeat(2) {
            val handler = DartWorkerReadyHandler(
                onReady = { starts++ },
                forward = { _, _ -> error("unexpected forwarding") },
            )
            handler.onMethodCall(MethodCall("ready", null), result {})
        }
        assertEquals(2, starts)
    }

    private fun result(onSuccess: (Any?) -> Unit) = object : MethodChannel.Result {
        override fun success(result: Any?) = onSuccess(result)
        override fun error(code: String, message: String?, details: Any?) =
            kotlin.error("unexpected error: $code")
        override fun notImplemented() = kotlin.error("unexpected notImplemented")
    }
}
