package com.bluebubbles.messaging.diagnostics

import android.util.Log
import org.json.JSONObject
import java.util.UUID

/**
 * Privacy-safe diagnostics for the SMS forwarding and registration paths.
 *
 * Do not add message bodies, addresses, identifiers, credentials, exception
 * messages, stack traces, or protocol bytes here. This output is intentionally
 * machine-readable so a support capture can select it exactly by prefix.
 */
object MessagingDiagnostics {
    const val SCHEMA = "openbubbles.messaging.diag.v1"
    const val PREFIX = "[MessagingDiag]"
    private const val TAG = "MessagingDiag"
    private val runId = UUID.randomUUID().toString()
    private val transports = setOf("sms", "mms", "rcs", "unknown")
    private val providers = setOf("openbubbles", "gmessages_companion", "unknown")

    fun event(
        event: String,
        transport: String = "unknown",
        provider: String = "openbubbles",
        outcome: String = "observed",
        code: String? = null,
        durationMs: Long? = null,
    ) {
        val payload = JSONObject()
            .put("schema", SCHEMA)
            .put("event", event)
            .put("run_id", runId)
            .put("operation_id", UUID.randomUUID().toString())
            .put("transport", transport.takeIf(transports::contains) ?: "unknown")
            .put("provider", provider.takeIf(providers::contains) ?: "unknown")
            .put("outcome", outcome)

        if (code != null) payload.put("code", code)
        if (durationMs != null) payload.put("duration_ms", durationMs)
        Log.i(TAG, "$PREFIX${payload}")
    }

    fun failure(
        event: String,
        transport: String,
        error: Throwable,
        provider: String = "openbubbles",
        durationMs: Long? = null,
    ) {
        event(
            event = event,
            transport = transport,
            provider = provider,
            outcome = "failure",
            code = error.javaClass.simpleName.ifBlank { "UnknownError" },
            durationMs = durationMs,
        )
    }
}
