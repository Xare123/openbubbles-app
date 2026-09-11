package com.bluebubbles.messaging.services.facetime

import java.io.File
import java.util.concurrent.Executors
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FaceTimeDiagnosticLogTest {
    @get:Rule val temporary = TemporaryFolder()
    private var now = 0L
    private var developer = true
    private var optIn = true
    private fun writer(directory: File, cap: Long = 65536) = FaceTimeDiagnosticLog(
        directory, { FaceTimeDiagnosticPolicy.shouldEnable(developer, optIn) }, { now }, { 1234L }, cap,
    )
    private fun contents(directory: File) = directory.listFiles().orEmpty()
        .filter { it.name.endsWith(".log") }.joinToString("") { it.readText() }

    @Test fun remoteLeaveRetainsOnlyCountsAndCallEquality() {
        val secret = "https://facetime.apple.com/join#private"
        val args = mapOf("callUuid" to secret, "active" to 1, "total" to 3,
            "handle" to "alice@example.test", "reason" to secret, "participant" to secret)
        val evidence = FaceTimeRemoteLeaveEvidence.fromArguments(args, secret)
        assertEquals(FaceTimeRemoteLeaveEvidence(1, 3, true), evidence)
        val directory = temporary.newFolder()
        assertTrue(writer(directory).record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "refreshed", remoteLeave = evidence))
        assertEquals("time_ms=1234 stage=remote_leave state=refreshed reason=participant_leave active=1 total=3 matches_active_call=true\n",
            contents(directory))
        assertFalse(contents(directory).contains(secret))
        assertFalse(contents(directory).contains("alice"))
        assertEquals(false, FaceTimeRemoteLeaveEvidence.fromArguments(args, "other-call").matchesActiveCall)
        assertEquals(null, FaceTimeRemoteLeaveEvidence.fromArguments(args, null).matchesActiveCall)
        assertEquals(null, FaceTimeRemoteLeaveEvidence.fromArguments(mapOf("callUuid" to ""), secret).matchesActiveCall)
    }

    @Test fun remoteLeaveRejectsUntypedFieldsAndBoundsEveryLine() {
        val malformed = FaceTimeRemoteLeaveEvidence.fromArguments(
            mapOf("callUuid" to 42, "active" to "private", "total" to 1.5), "private")
        assertEquals(FaceTimeRemoteLeaveEvidence(null, null, null), malformed)
        val line = FaceTimeDiagnosticPolicy.formatStage(FaceTimeDiagnosticStage.REMOTE_LEAVE,
            "alice@example.test", remoteLeave = malformed)
        assertEquals("stage=remote_leave state=unknown reason=participant_leave active=unavailable total=unavailable matches_active_call=unavailable", line)
        assertTrue(("time_ms=${Long.MAX_VALUE} $line\n").toByteArray().size <= FaceTimeDiagnosticLog.maxLineBytes)
        assertEquals(FaceTimeRemoteLeaveEvidence(0, 65535, null),
            FaceTimeRemoteLeaveEvidence.fromArguments(mapOf("active" to Long.MIN_VALUE, "total" to Long.MAX_VALUE), null))
        assertEquals("stage=close_reason state=web_leave",
            FaceTimeDiagnosticPolicy.formatStage(FaceTimeDiagnosticStage.CLOSE_REASON, "web_leave", remoteLeave = malformed))
    }

    @Test fun remoteLeaveIsOptInAndDoesNotConsumeCloseOrLifecycleBudget() {
        val directory = File(temporary.root, "remote-leave")
        val log = writer(directory)
        val before = FaceTimeRemoteLeaveEvidence(2, 2, true)
        val after = FaceTimeRemoteLeaveEvidence(1, 2, true)
        optIn = false
        assertFalse(log.record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "received", remoteLeave = before))
        assertFalse(directory.exists())
        optIn = true
        developer = false
        assertFalse(log.record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "received", remoteLeave = before))
        assertFalse(directory.exists())
        developer = true
        assertTrue(log.record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "received", remoteLeave = before))
        assertTrue(log.record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "refreshed", remoteLeave = after))
        assertTrue(log.record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "refresh_failed", remoteLeave = before))
        repeat(100) {
            assertFalse(log.record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "refreshed", remoteLeave = after.copy(total = it)))
        }
        assertTrue(log.record(FaceTimeDiagnosticStage.LEAVE, "requested"))
        assertTrue(log.record(FaceTimeDiagnosticStage.CLOSE_REASON, "web_leave"))
        assertTrue(log.record(FaceTimeDiagnosticStage.LIFECYCLE, "finishing_destroyed"))
        val retained = contents(directory)
        optIn = false
        now = 16000
        assertFalse(log.record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "received", remoteLeave = before))
        assertEquals(retained, contents(directory))
    }

    @Test fun remoteLeaveRotatesInsideExistingTwoFileCap() {
        val directory = temporary.newFolder()
        val sentinel = File(directory, "capture.log").apply { writeText("preserve") }
        val log = writer(directory, 256)
        repeat(100) {
            now += 16000
            assertTrue(log.record(FaceTimeDiagnosticStage.REMOTE_LEAVE, "refreshed",
                remoteLeave = FaceTimeRemoteLeaveEvidence(it, it + 1, false)))
        }
        assertTrue(File(directory, FaceTimeDiagnosticLog.currentName).length() in 1..256)
        assertTrue(File(directory, FaceTimeDiagnosticLog.previousName).length() in 1..256)
        assertEquals(3, directory.listFiles()!!.size)
        assertEquals("preserve", sentinel.readText())
    }

    @Test fun optOutCreatesNothingAndStopsAnExistingWriter() {
        val directory = File(temporary.root, "logs")
        val log = writer(directory)
        optIn = false
        assertFalse(log.record(FaceTimeDiagnosticStage.LIFECYCLE, "created"))
        assertFalse(directory.exists())
        optIn = true
        developer = false
        assertFalse(log.record(FaceTimeDiagnosticStage.LIFECYCLE, "created"))
        assertFalse(directory.exists())
        developer = true
        assertTrue(log.record(FaceTimeDiagnosticStage.LIFECYCLE, "created"))
        val before = contents(directory)
        optIn = false
        now += 60000
        assertFalse(log.record(FaceTimeDiagnosticStage.CLOSE_REASON, "web_leave"))
        assertEquals(before, contents(directory))
        optIn = true
        assertTrue(log.record(FaceTimeDiagnosticStage.CLOSE_REASON, "web_leave"))
    }

    @Test fun bothGenerationsRetainStagesAcrossWriterRestartWithoutLogcat() {
        val directory = temporary.newFolder()
        val first = writer(directory, 150)
        assertTrue(first.record(FaceTimeDiagnosticStage.LIFECYCLE, "created"))
        assertTrue(first.record(FaceTimeDiagnosticStage.ICE_STATE, "connected"))
        assertTrue(first.record(FaceTimeDiagnosticStage.MEDIA_BYTES, bytes = 4096))
        val restarted = writer(directory, 150)
        assertTrue(restarted.record(FaceTimeDiagnosticStage.CLOSE_REASON, "web_leave"))
        val files = directory.listFiles()!!.filter { it.name.endsWith(".log") }
        assertEquals(2, files.size)
        assertTrue(files.all { it.length() <= 150 })
        assertTrue(contents(directory).contains("stage=media_bytes bytes=4096"))
        assertTrue(contents(directory).contains("stage=close_reason state=web_leave"))
    }

    @Test fun rotationBoundsStorageAndPreservesUnrelatedFiles() {
        val directory = temporary.newFolder()
        val unrelated = File(directory, "bluebubbles-latest.log").apply { writeText("sentinel") }
        val log = writer(directory, 256)
        repeat(250) {
            now += 1100
            assertTrue(log.record(FaceTimeDiagnosticStage.MEDIA_BYTES, bytes = it.toLong()))
        }
        assertTrue(File(directory, FaceTimeDiagnosticLog.currentName).length() <= 256)
        assertTrue(File(directory, FaceTimeDiagnosticLog.previousName).length() <= 256)
        assertEquals(3, directory.listFiles()!!.size)
        assertEquals("sentinel", unrelated.readText())
    }

    @Test fun rateLimitCannotBeBypassedByChangingCountersAndCloseIsNotStarved() {
        val directory = temporary.newFolder()
        val log = writer(directory)
        assertTrue(log.record(FaceTimeDiagnosticStage.MEDIA_BYTES, bytes = 1))
        repeat(1000) { assertFalse(log.record(FaceTimeDiagnosticStage.MEDIA_BYTES, bytes = it.toLong() + 2)) }
        assertTrue(log.record(FaceTimeDiagnosticStage.CLOSE_REASON, "native_end_fallback"))
        assertFalse(log.record(FaceTimeDiagnosticStage.CLOSE_REASON, "native_end_fallback"))
        now = 1000
        assertTrue(log.record(FaceTimeDiagnosticStage.MEDIA_BYTES, bytes = 2))
        now = 2000
        assertFalse(log.record(FaceTimeDiagnosticStage.MEDIA_BYTES, bytes = 2))
        now = 16000
        assertTrue(log.record(FaceTimeDiagnosticStage.MEDIA_BYTES, bytes = 2))
    }

    @Test fun untrustedTextCannotReachDiskEvenIfItLooksLikeASafeToken() {
        val directory = temporary.newFolder()
        val log = writer(directory)
        val sensitive = listOf("secret-token", "alice@example.test", "192.0.2.1", "https://facetime.apple.com/join#token",
            "v=0\r\na=ice-pwd:secret", "a".repeat(100000), "user_handle", "123456789", "{\"body\":\"private\"}")
        for (stage in FaceTimeDiagnosticStage.entries) for (value in sensitive) {
            now += 16000
            assertTrue(log.record(stage, value, -1, -1))
        }
        val text = contents(directory)
        sensitive.filter { it.length < 1000 }.forEach { assertFalse(text.contains(it)) }
        assertTrue(text.lines().filter { it.isNotEmpty() }.all { it.toByteArray().size + 1 <= FaceTimeDiagnosticLog.maxLineBytes })
        assertEquals("stage=leave state=unknown", FaceTimeDiagnosticPolicy.formatStage(FaceTimeDiagnosticStage.LEAVE, "connected", 123, 456))
        assertEquals("stage=remote_audio_track count=65535", FaceTimeDiagnosticPolicy.formatStage(FaceTimeDiagnosticStage.REMOTE_AUDIO_TRACK, count = Int.MAX_VALUE))
    }

    @Test fun ioFailureDoesNotEscapeAndClearLogsCanBeFollowedByMoreEvents() {
        val invalidDirectory = temporary.newFile()
        assertFalse(writer(invalidDirectory).record(FaceTimeDiagnosticStage.CLOSE_REASON, "web_leave"))
        val directory = temporary.newFolder()
        val log = writer(directory)
        assertTrue(log.record(FaceTimeDiagnosticStage.LIFECYCLE, "created"))
        assertTrue(File(directory, FaceTimeDiagnosticLog.currentName).delete())
        assertTrue(log.record(FaceTimeDiagnosticStage.CLOSE_REASON, "declined"))
    }

    @Test fun concurrentCallbacksDoNotInterleaveOrBypassRateLimit() {
        val directory = temporary.newFolder()
        val log = writer(directory)
        val pool = Executors.newFixedThreadPool(4)
        try {
            val futures = (1..100).map { pool.submit<Boolean> { log.record(FaceTimeDiagnosticStage.LEAVE, "web_callback") } }
            assertEquals(1, futures.count { it.get() })
            assertEquals(1, contents(directory).lines().count { it.isNotEmpty() })
        } finally { pool.shutdownNow() }
    }

    @Test fun replayRetainsAtomicSamePeerSamplesAndTerminationWithoutLogcat() {
        val directory = temporary.newFolder()
        val log = writer(directory)
        fun sample(peer: Int?, bytes: Long?) = FaceTimeMediaEvidence(
            FaceTimeIceState.CONNECTED, 1, 0, bytes, true, peer,
        )
        assertTrue(log.record(FaceTimeDiagnosticStage.LIFECYCLE, "created"))
        assertTrue(log.record(FaceTimeDiagnosticStage.MEDIA_PROBE, "sampled", evidence = sample(1, 0)))
        now += 1000
        assertTrue(log.record(FaceTimeDiagnosticStage.MEDIA_PROBE, "sampled", evidence = sample(1, 128)))
        now += 1000
        assertTrue(log.record(FaceTimeDiagnosticStage.MEDIA_PROBE, "sampled", evidence = sample(2, 256)))
        now += 1000
        assertTrue(log.record(FaceTimeDiagnosticStage.MEDIA_PROBE, "sampled", evidence = sample(2, null)))
        // Counter spam cannot bypass the existing finite stage/state rate limit.
        repeat(100) {
            assertFalse(log.record(FaceTimeDiagnosticStage.MEDIA_PROBE, "sampled", evidence = sample(it + 3, 999)))
        }
        assertTrue(log.record(FaceTimeDiagnosticStage.LEAVE, "requested"))
        assertTrue(log.record(FaceTimeDiagnosticStage.CLOSE_REASON, "web_leave"))
        assertTrue(log.record(FaceTimeDiagnosticStage.LIFECYCLE, "finishing_destroyed"))
        val lines = contents(directory).lines().filter { it.isNotEmpty() }
        assertEquals(listOf(
            "time_ms=1234 stage=lifecycle state=created",
            "time_ms=1234 stage=media_probe state=sampled peer=1 ice=connected audio=1 video=0 bytes=0",
            "time_ms=1234 stage=media_probe state=sampled peer=1 ice=connected audio=1 video=0 bytes=128",
            "time_ms=1234 stage=media_probe state=sampled peer=2 ice=connected audio=1 video=0 bytes=256",
            "time_ms=1234 stage=media_probe state=sampled peer=2 ice=connected audio=1 video=0 bytes=unavailable",
            "time_ms=1234 stage=leave state=requested",
            "time_ms=1234 stage=close_reason state=web_leave",
            "time_ms=1234 stage=lifecycle state=finishing_destroyed",
        ), lines)
    }

    @Test fun sampleFieldsAreBoundedTypedAndRestrictedToSampledStage() {
        val evidence = FaceTimeMediaEvidence(FaceTimeIceState.UNKNOWN, -1, Int.MAX_VALUE, -1, false, -1)
        assertEquals("stage=media_probe state=sampled peer=none ice=unknown audio=0 video=65535 bytes=unavailable",
            FaceTimeDiagnosticPolicy.formatStage(FaceTimeDiagnosticStage.MEDIA_PROBE, "sampled", evidence = evidence))
        assertEquals("stage=close_reason state=web_leave",
            FaceTimeDiagnosticPolicy.formatStage(FaceTimeDiagnosticStage.CLOSE_REASON, "web_leave", evidence = evidence))
        val maximum = evidence.copy(peerId = Int.MAX_VALUE, mediaBytes = Long.MAX_VALUE)
        val line = FaceTimeDiagnosticPolicy.formatStage(FaceTimeDiagnosticStage.MEDIA_PROBE, "sampled", evidence = maximum)
        assertTrue(("time_ms=${Long.MAX_VALUE} $line\n").toByteArray().size <= FaceTimeDiagnosticLog.maxLineBytes)
    }
}
