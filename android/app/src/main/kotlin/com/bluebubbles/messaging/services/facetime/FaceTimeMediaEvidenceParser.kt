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
            val decodedPayload = payload
            JSONObject(decodedPayload)

            FaceTimeMediaEvidence(
                iceState = FaceTimeIceState.fromWireValue(
                    fieldValue(decodedPayload, "iceState")
                        .takeUnless { it == null || it.isBlank() || it == "null" },
                ),
                remoteAudioTracks = parseBoundedInt(fieldValue(decodedPayload, "remoteAudioTracks")),
                remoteVideoTracks = parseBoundedInt(fieldValue(decodedPayload, "remoteVideoTracks")),
                mediaBytes = parseNullableBoundedLong(fieldValue(decodedPayload, "mediaBytes")),
                webLeaveVisible = fieldValue(decodedPayload, "webLeaveVisible")?.toBoolean() ?: false,
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun decodeJavascriptResult(raw: String): String? {
        if (raw.startsWith("{")) return raw
        if (!raw.startsWith("\"") || !raw.endsWith("\"")) return null

        val result = StringBuilder()
        var index = 1
        val end = raw.length - 1
        while (index < end) {
            val character = raw[index]
            if (character != '\\') {
                if (character == '"') return null
                result.append(character)
                index += 1
                continue
            }

            if (index + 1 >= end) return null
            when (val escaped = raw[index + 1]) {
                '"', '\\', '/' -> result.append(escaped)
                'b' -> result.append('\b')
                'f' -> result.append('\u000C')
                'n' -> result.append('\n')
                'r' -> result.append('\r')
                't' -> result.append('\t')
                'u' -> {
                    if (index + 5 >= end) return null
                    val codePoint = raw.substring(index + 2, index + 6).toIntOrNull(16) ?: return null
                    result.append(codePoint.toChar())
                    index += 4
                }
                else -> return null
            }
            index += 2
        }
        return result.toString()
    }

    private fun parseBoundedInt(value: String?): Int =
        parseBoundedLong(value, Int.MAX_VALUE.toLong()).toInt()

    private fun parseNullableBoundedLong(value: String?): Long? {
        if (value == null || value == "null") return null
        return parseBoundedLong(value, Long.MAX_VALUE)
    }

    private fun fieldValue(payload: String, key: String): String? {
        val token = Regex(
            "\\\"${Regex.escape(key)}\\\"\\s*:\\s*(\\\"(?:\\\\.|[^\\\"\\\\])*\\\"|[^,}\\s]+)"
        ).find(payload)?.groupValues?.get(1) ?: return null
        if (!token.startsWith("\"") || !token.endsWith("\"")) return token
        return token.substring(1, token.length - 1)
            .replace("\\\"", "\"")
            .replace("\\/", "/")
            .replace("\\\\", "\\")
    }

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
