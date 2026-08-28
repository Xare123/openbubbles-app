package com.bluebubbles.messaging.services.facetime

import com.google.gson.JsonElement
import com.google.gson.JsonParser

/** Parses the JSON string returned by WebView.evaluateJavascript safely. */
internal object FaceTimeMediaEvidenceParser {
    fun parse(rawResult: String?): FaceTimeMediaEvidence? {
        val raw = rawResult?.trim().orEmpty()
        if (raw.isEmpty() || raw == "null" || raw == "undefined") return null

        return runCatching {
            val payload = decodeEvaluateJavascriptResult(raw)
            val peers = payload.getAsJsonArray("peers")
                ?.mapNotNull(::parsePeer)
                .orEmpty()
            FaceTimeMediaEvidence(
                peerId = payload.get("peerId")?.asString?.toLongOrNull()
                    ?.takeIf { it > 0 && it <= Int.MAX_VALUE }
                    ?.toInt(),
                iceState = FaceTimeIceState.fromWireValue(payload.get("iceState")?.asString),
                remoteAudioTracks = boundedInt(payload.get("remoteAudioTracks")),
                remoteVideoTracks = boundedInt(payload.get("remoteVideoTracks")),
                mediaBytes = boundedLong(payload.get("mediaBytes")),
                webLeaveVisible = payload.get("webLeaveVisible")?.asBoolean ?: false,
                peers = peers,
            )
        }.getOrNull()
    }

    private fun parsePeer(value: JsonElement): FaceTimePeerMediaEvidence? {
        val payload = value.takeIf { it.isJsonObject }?.asJsonObject ?: return null
        return FaceTimePeerMediaEvidence(
            peerId = payload.get("peerId")?.asString?.toLongOrNull()
                ?.takeIf { it > 0 && it <= Int.MAX_VALUE }
                ?.toInt(),
            iceState = FaceTimeIceState.fromWireValue(payload.get("iceState")?.asString),
            remoteAudioTracks = boundedInt(payload.get("remoteAudioTracks")),
            remoteVideoTracks = boundedInt(payload.get("remoteVideoTracks")),
            mediaBytes = boundedLong(payload.get("mediaBytes")),
        )
    }

    private fun decodeEvaluateJavascriptResult(raw: String): com.google.gson.JsonObject {
        val decoded = JsonParser.parseString(raw)
        val json = if (decoded.isJsonPrimitive && decoded.asJsonPrimitive.isString) {
            JsonParser.parseString(decoded.asString)
        } else {
            decoded
        }
        return json.takeIf { it.isJsonObject }?.asJsonObject
            ?: throw IllegalArgumentException("FaceTime media evidence was not an object")
    }

    private fun boundedInt(value: JsonElement?): Int = boundedIntOrNull(value) ?: 0

    private fun boundedIntOrNull(value: JsonElement?): Int? =
        value?.takeIf { it.isJsonPrimitive }?.asString?.toBigDecimalOrNull()
            ?.takeIf { it.signum() >= 0 && it.scale() <= 0 }
            ?.toBigInteger()
            ?.coerceAtMost(Int.MAX_VALUE.toBigInteger())
            ?.toInt()

    private fun boundedLong(value: JsonElement?): Long? =
        if (value == null || value.isJsonNull || !value.isJsonPrimitive) {
            null
        } else {
            value.asString.toBigDecimalOrNull()
                ?.takeIf { it.signum() > 0 && it.scale() <= 0 }
                ?.toBigInteger()
                ?.takeIf { it <= Long.MAX_VALUE.toBigInteger() }
                ?.toLong()
        }
}
