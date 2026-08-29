package com.bluebubbles.messaging.services.facetime

internal enum class FaceTimeJoinOutcome {
    CLICKED,
    ALREADY_JOINED,
    MISSING,
    DISABLED,
    HIDDEN,
    UNKNOWN,
    MEDIA_PENDING,
    MEDIA_CONNECTED,
    MEDIA_FAILED,
}

internal enum class FaceTimeIceState {
    NEW,
    CHECKING,
    CONNECTED,
    COMPLETED,
    DISCONNECTED,
    FAILED,
    CLOSED,
    UNKNOWN,
    ;

    companion object {
        fun fromWireValue(rawValue: String?): FaceTimeIceState = when (rawValue?.lowercase()) {
            "new" -> NEW
            "checking" -> CHECKING
            "connected" -> CONNECTED
            "completed" -> COMPLETED
            "disconnected" -> DISCONNECTED
            "failed" -> FAILED
            "closed" -> CLOSED
            else -> UNKNOWN
        }
    }
}

internal data class FaceTimeMediaEvidence(
    val iceState: FaceTimeIceState,
    val remoteAudioTracks: Int,
    val remoteVideoTracks: Int,
    val mediaBytes: Long?,
    val webLeaveVisible: Boolean,
    val peerId: Int? = null,
    val videoFramesDecoded: Long? = null,
    val audioSamplesReceived: Long? = null,
    val audioConcealedSamples: Long? = null,
    val audioJitterBufferEmittedCount: Long? = null,
) {
    val hasRemoteTrack: Boolean
        get() = remoteAudioTracks > 0 || remoteVideoTracks > 0

    val hasConnectedIce: Boolean
        get() = iceState == FaceTimeIceState.CONNECTED || iceState == FaceTimeIceState.COMPLETED

    val isConnected: Boolean
        get() = hasConnectedIce && hasRemoteTrack

    val audioDecodedSamples: Long?
        get() = audioSamplesReceived?.let { total ->
            (total - (audioConcealedSamples ?: 0L)).coerceAtLeast(0L)
        }
}

internal data class FaceTimeJoinDecision(
    val outcome: FaceTimeJoinOutcome,
    val joined: Boolean,
    val revealManualRecovery: Boolean,
    val retry: Boolean,
)

internal enum class FaceTimeIntentDisposition {
    ACCEPTED,
    DUPLICATE,
    REJECTED_MISMATCHED_CALL,
    REJECTED_MISSING_CALL_ID,
}

internal enum class FaceTimeNativeEndPlacement {
    TOP_RIGHT,
}

internal object FaceTimeConnectionProbePolicy {
    const val maxProbes = 80
    const val initialDelayMillis = 500L
    const val pendingDelayMillis = 1500L
    const val connectedDelayMillis = 5000L
    // A five-second getStats interval can be flat during silence or a delayed
    // WebRTC report. Three consecutive unhealthy samples gives a 15-second
    // bounded grace window while still surfacing an actual media stall.
    const val consecutiveStalledSamplesBeforeMediaLoss = 3
}

/** Keeps a new FaceTime intent attached to one call. */
internal class FaceTimeCallLifecycle {
    private var activeCallUuid: String? = null

    fun acceptIntent(incomingCallUuid: String?): FaceTimeIntentDisposition {
        val active = activeCallUuid
        if (active == null) {
            if (incomingCallUuid == null) {
                return FaceTimeIntentDisposition.REJECTED_MISSING_CALL_ID
            }
            activeCallUuid = incomingCallUuid
            return FaceTimeIntentDisposition.ACCEPTED
        }

        return when {
            incomingCallUuid == active -> FaceTimeIntentDisposition.DUPLICATE
            incomingCallUuid == null -> FaceTimeIntentDisposition.REJECTED_MISSING_CALL_ID
            else -> FaceTimeIntentDisposition.REJECTED_MISMATCHED_CALL
        }
    }

    fun reset() {
        activeCallUuid = null
    }
}

internal object FaceTimeControlPolicy {
    /**
     * The page owns its Leave button when it is visible. Suppressing the
     * Android overlay in that state is safer than guessing at an Apple-owned
     * control's coordinates after a WebView layout change.
     */
    fun shouldShowNativeEndControl(
        webLeaveVisible: Boolean,
        webLeaveObservationFresh: Boolean,
    ): Boolean = webLeaveObservationFresh && !webLeaveVisible

    fun nativeEndPlacement(): FaceTimeNativeEndPlacement = FaceTimeNativeEndPlacement.TOP_RIGHT
}

internal class FaceTimeJoinPolicy(
    private val manualRecoveryAttempt: Int = 20,
    private val maxAttempts: Int = 80,
) {
    private var previousPeerId: Int? = null
    private var previousInboundMediaBytes: Long? = null
    private var previousVideoFramesDecoded: Long? = null
    private var previousAudioDecodedSamples: Long? = null
    private var consecutiveStalledMediaSamples: Int = 0

    var attempts: Int = 0
        private set

    var admissionRequested: Boolean = false
        private set

    var joined: Boolean = false
        private set

    var completedJoin: Boolean = false
        private set

    fun record(rawResult: String?): FaceTimeJoinDecision {
        attempts += 1
        val outcome = parseOutcome(rawResult)
        if (outcome == FaceTimeJoinOutcome.CLICKED || outcome == FaceTimeJoinOutcome.ALREADY_JOINED) {
            admissionRequested = true
        }

        // A click and a visible Leave button are only signaling evidence. The
        // WebView must later report connected ICE and advancing inbound media.
        return decision(outcome)
    }

    fun recordMediaEvidence(evidence: FaceTimeMediaEvidence): FaceTimeJoinDecision {
        val currentBytes = evidence.mediaBytes
        val previousBytes = previousInboundMediaBytes
        val previousVideoFrames = previousVideoFramesDecoded
        val previousAudioSamples = previousAudioDecodedSamples
        val currentPeerId = evidence.peerId
        val currentVideoFramesDecoded = evidence.videoFramesDecoded
        val currentAudioDecodedSamples = evidence.audioDecodedSamples
        // A zero byte count is a reset or pre-media sample, not a baseline.
        // Decoded counters may legitimately begin at zero and are handled below.
        val hasTransportCounter = currentBytes != null && currentBytes in 1 until Long.MAX_VALUE
        val hasDecodedCounter = currentVideoFramesDecoded != null ||
            currentAudioDecodedSamples != null
        val validBaseline = evidence.isConnected &&
            currentPeerId != null &&
            (hasTransportCounter || hasDecodedCounter)
        val samePeer = validBaseline && previousPeerId == currentPeerId
        val transportIsAdvancing = samePeer &&
            currentBytes != null &&
            previousBytes != null &&
            currentBytes > previousBytes
        val decodedMediaIsAdvancing = samePeer && (
            currentVideoFramesDecoded != null &&
                previousVideoFrames != null &&
                currentVideoFramesDecoded > previousVideoFrames ||
            currentAudioDecodedSamples != null &&
                previousAudioSamples != null &&
                currentAudioDecodedSamples > previousAudioSamples
        )
        val decodedCountersAvailable = currentVideoFramesDecoded != null ||
            currentAudioDecodedSamples != null ||
            samePeer && (previousVideoFrames != null || previousAudioSamples != null)
        // Decoded counters outrank RTP bytes when the WebView exposes them.
        // bytesReceived remains a compatibility fallback for older engines.
        val mediaIsAdvancing = if (decodedCountersAvailable) {
            decodedMediaIsAdvancing
        } else {
            transportIsAdvancing
        }

        previousPeerId = if (validBaseline) currentPeerId else null
        previousInboundMediaBytes = if (validBaseline) currentBytes else null
        previousVideoFramesDecoded = if (validBaseline) currentVideoFramesDecoded else null
        previousAudioDecodedSamples = if (validBaseline) currentAudioDecodedSamples else null

        if (mediaIsAdvancing) {
            consecutiveStalledMediaSamples = 0
            joined = true
            completedJoin = true
            return decision(FaceTimeJoinOutcome.MEDIA_CONNECTED)
        }

        val terminalIceFailure = evidence.iceState == FaceTimeIceState.FAILED ||
            evidence.iceState == FaceTimeIceState.CLOSED
        if (!completedJoin) {
            joined = false
            return decision(if (terminalIceFailure) FaceTimeJoinOutcome.MEDIA_FAILED else FaceTimeJoinOutcome.MEDIA_PENDING)
        }

        if (terminalIceFailure) {
            consecutiveStalledMediaSamples = FaceTimeConnectionProbePolicy.consecutiveStalledSamplesBeforeMediaLoss
            joined = false
            return decision(FaceTimeJoinOutcome.MEDIA_FAILED)
        }

        consecutiveStalledMediaSamples += 1
        if (consecutiveStalledMediaSamples < FaceTimeConnectionProbePolicy.consecutiveStalledSamplesBeforeMediaLoss) {
            // Preserve the admitted call through a bounded grace window. A
            // subsequent advancing sample immediately clears the streak.
            joined = true
            return decision(FaceTimeJoinOutcome.MEDIA_CONNECTED)
        }

        joined = false
        return decision(FaceTimeJoinOutcome.MEDIA_FAILED)
    }

    fun reset() {
        attempts = 0
        admissionRequested = false
        joined = false
        completedJoin = false
        previousPeerId = null
        previousInboundMediaBytes = null
        previousVideoFramesDecoded = null
        previousAudioDecodedSamples = null
        consecutiveStalledMediaSamples = 0
    }

    private fun decision(outcome: FaceTimeJoinOutcome): FaceTimeJoinDecision = FaceTimeJoinDecision(
        outcome = outcome,
        joined = joined,
        revealManualRecovery = joined || attempts >= manualRecoveryAttempt,
        retry = !joined && !completedJoin && attempts < maxAttempts,
    )

    companion object {
        fun parseOutcome(rawResult: String?): FaceTimeJoinOutcome {
            val normalized = rawResult
                ?.trim()
                ?.removeSurrounding("\"")
                ?.lowercase()

            return when (normalized) {
                "clicked" -> FaceTimeJoinOutcome.CLICKED
                "already-joined" -> FaceTimeJoinOutcome.ALREADY_JOINED
                "missing" -> FaceTimeJoinOutcome.MISSING
                "disabled" -> FaceTimeJoinOutcome.DISABLED
                "hidden" -> FaceTimeJoinOutcome.HIDDEN
                else -> FaceTimeJoinOutcome.UNKNOWN
            }
        }
    }
}
