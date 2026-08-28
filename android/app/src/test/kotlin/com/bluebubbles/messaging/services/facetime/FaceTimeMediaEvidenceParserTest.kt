package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeMediaEvidenceParserTest {
    @Test
    fun parsesRemoteParticipantCountFromWebViewResult() {
        val evidence = FaceTimeMediaEvidenceParser.parse(
            evaluateResult("""{"peerId":2,"iceState":"connected","remoteAudioTracks":1,"mediaBytes":12,"webLeaveVisible":true,"remoteParticipantCount":1}""")
        )

        assertEquals(1, evidence?.remoteParticipantCount)
        assertTrue(evidence?.hasRemoteParticipant == true)
    }

    @Test
    fun malformedResultIsUnavailable() {
        assertNull(FaceTimeMediaEvidenceParser.parse("{not-json"))
        assertNull(FaceTimeMediaEvidenceParser.parse("null"))
    }

    @Test
    fun negativeAndFractionalCountersFailClosed() {
        val evidence = FaceTimeMediaEvidenceParser.parse(
            """{"iceState":"connected","remoteAudioTracks":-1,"remoteVideoTracks":1.5,"mediaBytes":-2}"""
        )

        assertEquals(0, evidence?.remoteAudioTracks)
        assertEquals(0, evidence?.remoteVideoTracks)
        assertNull(evidence?.mediaBytes)
        assertFalse(evidence?.hasRemoteMedia == true)
    }

    private fun evaluateResult(json: String): String =
        "\"" + json.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
