package com.bluebubbles.messaging.services.facetime

import com.google.gson.JsonParser

internal data class FaceTimeJoinEvidence(
    val outcome: FaceTimeJoinOutcome,
)

/** Parses the bounded JSON result returned by the join-button probe. */
internal object FaceTimeJoinEvidenceParser {
    fun parse(rawResult: String?): FaceTimeJoinEvidence? {
        val raw = rawResult?.trim().orEmpty()
        if (raw.isEmpty() || raw == "null" || raw == "undefined") return null

        return runCatching {
            val payload = decodeEvaluateJavascriptResult(raw)
            val outcome = FaceTimeJoinPolicy.parseOutcome(
                payload.get("outcome")?.takeIf { it.isJsonPrimitive }?.asString,
            )
            if (outcome == FaceTimeJoinOutcome.UNKNOWN) return null
            FaceTimeJoinEvidence(
                outcome = outcome,
            )
        }.getOrNull()
    }

    private fun decodeEvaluateJavascriptResult(raw: String): com.google.gson.JsonObject {
        val decoded = JsonParser.parseString(raw)
        val json = if (decoded.isJsonPrimitive && decoded.asJsonPrimitive.isString) {
            JsonParser.parseString(decoded.asString)
        } else {
            decoded
        }
        return json.takeIf { it.isJsonObject }?.asJsonObject
            ?: throw IllegalArgumentException("FaceTime join evidence was not an object")
    }
}
