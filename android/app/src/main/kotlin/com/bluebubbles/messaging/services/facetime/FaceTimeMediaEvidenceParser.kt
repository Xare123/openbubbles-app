package com.bluebubbles.messaging.services.facetime

import org.json.JSONObject
import java.math.BigDecimal
import java.math.BigInteger

/** Parses the JSON string returned by WebView.evaluateJavascript safely. */
internal object FaceTimeMediaEvidenceParser {
    fun parse(rawResult: String?): FaceTimeMediaEvidence? {
        val raw = rawResult?.trim()
        if (raw.isNullOrEmpty() || raw == "null" || raw == "undefined") return null

        return try {
            val payload = decodeJavascriptResult(raw)?.trim() ?: return null
            if (!payload.startsWith("{") || !payload.endsWith("}")) return null
            val json = JSONObject(payload)

            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.fromWireValue(
                    fieldValue(json, "iceState")
                        .takeUnless { it == null || it.isBlank() || it == "null" },
                ),
                remoteAudioTracks = parseBoundedInt(fieldValue(json, "remoteAudioTracks")),
                remoteVideoTracks = parseBoundedInt(fieldValue(json, "remoteVideoTracks")),
                mediaBytes = parseNullableBoundedLong(fieldValue(json, "mediaBytes")),
                webLeaveVisible = json.optBoolean("webLeaveVisible", false),
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun decodeJavascriptResult(raw: String): String? {
        if (raw.startsWith("{")) return raw
        return JSONObject("{\"value\":$raw}").getString("value")
    }

    private fun parseBoundedInt(value: String?): Int =
        parseBoundedLong(value, Int.MAX_VALUE.toLong()).toInt()

    private fun parseNullableBoundedLong(value: String?): Long? {
        if (value == null || value == "null") return null
        return parseBoundedLong(value, Long.MAX_VALUE)
    }

    private fun fieldValue(json: JSONObject, key: String): String? =
        json.opt(key)?.takeUnless { it === JSONObject.NULL }?.toString()

    private fun parseBoundedLong(value: String?, maximum: Long): Long {
        val decimal = value?.toBigDecimalOrNull() ?: return 0L
        if (decimal.signum() <= 0) return 0L

        val integer = decimal.toBigIntegerExactOrNull() ?: return 0L
        return if (integer > BigInteger.valueOf(maximum)) {
            maximum
        } else {
            integer.toLong()
        }
    }

    private fun BigDecimal.toBigIntegerExactOrNull(): BigInteger? = try {
        toBigIntegerExact()
    } catch (_: ArithmeticException) {
        null
    }
}
