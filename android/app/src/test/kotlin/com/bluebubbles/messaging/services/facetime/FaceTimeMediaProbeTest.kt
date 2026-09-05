package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeMediaProbeTest {
    private class Fixture {
        var url = "https://facetime.apple.com/join"
        var clock = 0L
        var holdReads = false
        var holdStart = false
        var evaluations = 0
        val responses = ArrayDeque<String?>()
        val callbacks = mutableListOf<(String?) -> Unit>()
        val scheduled = mutableListOf<Pair<Long, () -> Unit>>()
        val results = mutableListOf<String?>()
        val probe = FaceTimeMediaProbe(
            evaluate = { script, callback ->
                evaluations++
                if (script.contains("const request = {")) {
                    if (holdStart) callbacks.add(callback) else callback("\"started\"")
                } else {
                    if (holdReads) callbacks.add(callback)
                    else callback(responses.removeFirstOrNull() ?: "\"pending\"")
                }
            },
            schedule = { delay, action -> scheduled.add(clock + delay to action) },
            currentUrl = { url },
        )

        fun advance(milliseconds: Long) {
            val end = clock + milliseconds
            while (true) {
                val next = scheduled.minByOrNull { it.first } ?: break
                if (next.first > end) break
                scheduled.remove(next)
                clock = next.first
                next.second()
            }
            clock = end
        }

        fun request() = probe.request { results.add(it) }
    }

    private fun sample(bytes: Long): String =
        "\"{\\\"peerId\\\":1,\\\"iceState\\\":\\\"connected\\\",\\\"remoteAudioTracks\\\":1,\\\"remoteVideoTracks\\\":0,\\\"mediaBytes\\\":" +
            bytes + ",\\\"webLeaveVisible\\\":true}\""

    @Test
    fun deliversResolvedAdvancingSamplesToTheRealParserAndJoinPolicy() {
        val fixture = Fixture()
        val policy = FaceTimeJoinPolicy()
        fixture.responses.add("\"pending\"")
        fixture.responses.add(sample(100))
        fixture.request()
        assertTrue(fixture.results.isEmpty())
        fixture.advance(FaceTimeMediaProbe.pollMillis)
        val first = FaceTimeMediaEvidenceParser.parse(fixture.results.single())!!
        assertEquals(100L, first.mediaBytes)
        assertFalse(policy.recordMediaEvidence(first).joined)
        fixture.responses.add(sample(200))
        fixture.request()
        val second = FaceTimeMediaEvidenceParser.parse(fixture.results.last())!!
        assertTrue(policy.recordMediaEvidence(second).joined)
        fixture.advance(FaceTimeMediaProbe.timeoutMillis)
        assertEquals(2, fixture.results.size) // old timeout cannot redeliver
    }

    @Test
    fun navigationInvalidatesOutstandingCallbacksAndAllowsANewProbe() {
        val fixture = Fixture()
        fixture.holdReads = true
        fixture.request()
        val oldRead = fixture.callbacks.single()
        fixture.probe.invalidate()
        assertEquals(listOf<String?>(null), fixture.results)
        fixture.holdReads = false
        fixture.responses.add(sample(200))
        fixture.request()
        oldRead(sample(900))
        assertEquals(listOf(null, sample(200)), fixture.results)
    }

    @Test
    fun navigationBetweenProbesRequiresTwoNewSamplesAndKeepsHangupAvailable() {
        val policy = FaceTimeJoinPolicy()
        policy.recordMediaEvidence(FaceTimeMediaEvidenceParser.parse(sample(100))!!)
        assertTrue(policy.recordMediaEvidence(FaceTimeMediaEvidenceParser.parse(sample(200))!!).joined)
        policy.recordMediaEvidence(FaceTimeMediaEvidence(
            FaceTimeIceState.UNKNOWN, 0, 0, null, false,
        ))
        assertFalse(policy.joined)
        // Same peer ID in a new document cannot reuse the old byte baseline.
        assertFalse(policy.recordMediaEvidence(FaceTimeMediaEvidenceParser.parse(sample(900))!!).joined)
        assertTrue(FaceTimeControlPolicy.shouldShowNativeEndControl())
        assertTrue(policy.recordMediaEvidence(FaceTimeMediaEvidenceParser.parse(sample(1000))!!).joined)
    }

    @Test
    fun teardownDiscardsLateCallbacksAndScheduledRetries() {
        val fixture = Fixture()
        fixture.holdReads = true
        fixture.request()
        val callback = fixture.callbacks.single()
        fixture.probe.close()
        callback(sample(100))
        fixture.advance(10000)
        assertTrue(fixture.results.isEmpty())
        assertEquals(2, fixture.evaluations)
    }

    @Test
    fun originIsCheckedBeforeDeliveryAsWellAsBeforeEvaluation() {
        val fixture = Fixture()
        fixture.holdReads = true
        fixture.request()
        fixture.url = "https://other.invalid"
        fixture.callbacks.single()(sample(100))
        assertEquals(listOf<String?>(null), fixture.results)
    }

    @Test
    fun pendingStatsAndMissingWebViewCallbackTimeOutOnce() {
        for (holdStart in listOf(false, true)) {
            val fixture = Fixture()
            fixture.holdStart = holdStart
            fixture.request()
            fixture.advance(FaceTimeMediaProbe.timeoutMillis + 1000)
            assertEquals(listOf<String?>(null), fixture.results)
            fixture.callbacks.forEach { it("\"started\"") }
            assertEquals(1, fixture.results.size)
        }
    }

    @Test
    fun malformedAndNullResultsAreNotConnectionEvidence() {
        for (raw in listOf("{}", "null", "\"not-json\"")) {
            val fixture = Fixture()
            fixture.responses.add(raw)
            fixture.request()
            val evidence = FaceTimeMediaEvidenceParser.parse(fixture.results.single())
            assertFalse(evidence?.isConnected == true)
            assertTrue(FaceTimeControlPolicy.shouldShowNativeEndControl())
        }
    }

    @Test
    fun acceptsOnlyTheExactHttpsFaceTimeOrigin() {
        assertTrue(FaceTimeMediaProbe.isTrustedUrl("https://facetime.apple.com/join"))
        assertTrue(FaceTimeMediaProbe.isTrustedUrl("https://facetime.apple.com:443/join"))
        for (url in listOf(null, "", "http://facetime.apple.com", "https://facetime.apple.com:444",
            "https://facetime.apple.com.attacker.invalid", "https://user@facetime.apple.com",
            "javascript:alert(1)", "not a url")) {
            assertFalse(FaceTimeMediaProbe.isTrustedUrl(url))
        }
    }

    @Test
    fun cachedPageRequiresBothTheSameCallAndTheSameLink() {
        assertTrue(FaceTimeMediaProbe.canReusePage("link", "a", "link", "a"))
        assertFalse(FaceTimeMediaProbe.canReusePage("link", "a", "link", "b"))
        assertFalse(FaceTimeMediaProbe.canReusePage("old", "a", "new", "a"))
        assertFalse(FaceTimeMediaProbe.canReusePage("link", null, "link", null))
        assertFalse(FaceTimeMediaProbe.canReusePage("link", "", "link", ""))
    }
}
