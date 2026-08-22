package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeMediaEvidenceParserTest {
    @Test
    fun nullAndEmptyJavascriptResultsAreUnavailable() {
        assertNull(FaceTimeMediaEvidenceParser.parse(null))
        assertNull(FaceTimeMediaEvidenceParser.parse("null"))
        assertNull(FaceTimeMediaEvidenceParser.parse(" undefined "))
        assertNull(FaceTimeMediaEvidenceParser.parse(""))
    }

    @Test
    fun parsesEscapedEvaluateJavascriptJson() {
        val json = """{"iceState":"connected","remoteAudioTracks":1,"remoteVideoTracks":1,"mediaBytes":128,"webLeaveVisible":true}"""

        val evidence = FaceTimeMediaEvidenceParser.parse(asEvaluateJavascriptString(json))

        assertEquals(FaceTimeIceState.CONNECTED, evidence?.iceState)
        assertEquals(1, evidence?.remoteAudioTracks)
        assertEquals(1, evidence?.remoteVideoTracks)
        assertEquals(128L, evidence?.mediaBytes)
        assertTrue(evidence?.webLeaveVisible == true)
        assertTrue(evidence?.isConnected == true)
    }

    @Test
    fun parsesDirectJsonObjectToo() {
        val evidence = FaceTimeMediaEvidenceParser.parse(
            """{"iceState":"completed","remoteAudioTracks":1,"remoteVideoTracks":0}"""
        )

        assertEquals(FaceTimeIceState.COMPLETED, evidence?.iceState)
        assertEquals(1, evidence?.remoteAudioTracks)
        assertEquals(0, evidence?.remoteVideoTracks)
        assertNull(evidence?.mediaBytes)
    }

    @Test
    fun malformedOuterOrInnerJsonReturnsUnavailable() {
        assertNull(FaceTimeMediaEvidenceParser.parse("{not-json"))
        assertNull(FaceTimeMediaEvidenceParser.parse(asEvaluateJavascriptString("{not-json")))
        assertNull(FaceTimeMediaEvidenceParser.parse(asEvaluateJavascriptString("not an object")))
    }

    @Test
    fun missingAndExplicitlyNullMediaBytesRemainNull() {
        val missing = FaceTimeMediaEvidenceParser.parse(
            """{"iceState":"connected","remoteAudioTracks":1}"""
        )
        val explicitNull = FaceTimeMediaEvidenceParser.parse(
            """{"iceState":"connected","remoteAudioTracks":1,"mediaBytes":null}"""
        )

        assertNull(missing?.mediaBytes)
        assertNull(explicitNull?.mediaBytes)
    }

    @Test
    fun unknownIceStateIsSafeAndDoesNotClaimConnected() {
        val evidence = FaceTimeMediaEvidenceParser.parse(
            """{"iceState":"future-state","remoteAudioTracks":1,"remoteVideoTracks":1,"mediaBytes":1}"""
        )

        assertEquals(FaceTimeIceState.UNKNOWN, evidence?.iceState)
        assertTrue(evidence?.hasRemoteTrack == true)
        assertTrue(evidence?.isConnected == false)
    }

    @Test
    fun negativeCountersAndBytesClampToZero() {
        val evidence = FaceTimeMediaEvidenceParser.parse(
            """{"iceState":"connected","remoteAudioTracks":-2,"remoteVideoTracks":-9,"mediaBytes":-1}"""
        )

        assertEquals(0, evidence?.remoteAudioTracks)
        assertEquals(0, evidence?.remoteVideoTracks)
        assertEquals(0L, evidence?.mediaBytes)
        assertTrue(evidence?.isConnected == false)
    }

    @Test
    fun oversizedValuesSaturateWithoutOverflow() {
        val evidence = FaceTimeMediaEvidenceParser.parse(
            """{"iceState":"connected","remoteAudioTracks":999999999999999999999999999999,"remoteVideoTracks":1,"mediaBytes":999999999999999999999999999999999999999999999999999999999999}"""
        )

        assertEquals(Int.MAX_VALUE, evidence?.remoteAudioTracks)
        assertEquals(1, evidence?.remoteVideoTracks)
        assertEquals(Long.MAX_VALUE, evidence?.mediaBytes)
    }

    @Test
    fun nonIntegralNumericValuesAreIgnoredSafely() {
        val evidence = FaceTimeMediaEvidenceParser.parse(
            """{"remoteAudioTracks":1.5,"remoteVideoTracks":"2.5","mediaBytes":"3.25"}"""
        )

        assertEquals(0, evidence?.remoteAudioTracks)
        assertEquals(0, evidence?.remoteVideoTracks)
        assertEquals(0L, evidence?.mediaBytes)
    }

    private fun asEvaluateJavascriptString(json: String): String =
        "\"" + json.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
