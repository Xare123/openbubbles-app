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
    val peers: List<FaceTimePeerMediaEvidence> = emptyList(),
) {
    val hasRemoteTrack: Boolean
        get() = remoteAudioTracks > 0 || remoteVideoTracks > 0

    val hasConnectedIce: Boolean
        get() = iceState == FaceTimeIceState.CONNECTED || iceState == FaceTimeIceState.COMPLETED

    val hasRemoteMedia: Boolean
        get() = hasConnectedIce && peerId != null && hasRemoteTrack && (mediaBytes ?: 0) > 0

    fun peerSamples(): List<FaceTimePeerMediaEvidence> = peers.ifEmpty {
        listOf(
            FaceTimePeerMediaEvidence(
                peerId = peerId,
                iceState = iceState,
                remoteAudioTracks = remoteAudioTracks,
                remoteVideoTracks = remoteVideoTracks,
                mediaBytes = mediaBytes,
            ),
        )
    }
}

/** A single RTCPeerConnection sample returned by the page's native bridge. */
internal data class FaceTimePeerMediaEvidence(
    val peerId: Int?,
    val iceState: FaceTimeIceState,
    val remoteAudioTracks: Int,
    val remoteVideoTracks: Int,
    val mediaBytes: Long?,
) {
    val hasRemoteTrack: Boolean
        get() = remoteAudioTracks > 0 || remoteVideoTracks > 0

    val hasConnectedIce: Boolean
        get() = iceState == FaceTimeIceState.CONNECTED || iceState == FaceTimeIceState.COMPLETED

    val isUsable: Boolean
        get() = peerId != null && hasConnectedIce && hasRemoteTrack && mediaBytes != null
}

internal data class FaceTimeJoinDecision(
    val outcome: FaceTimeJoinOutcome,
    val joined: Boolean,
    val revealManualRecovery: Boolean,
    val retry: Boolean,
)

internal object FaceTimeConnectionProbePolicy {
    // The old twelve-probe cap could expire before a valid remote RTP stream
    // started. Keep probing for about a minute, with a second hard count bound
    // in case callbacks arrive unusually quickly.
    const val maxDurationMillis = 60_000L
    const val maxProbes = 48
    const val initialDelayMillis = 500L
    const val pendingDelayMillis = 1500L

    fun shouldContinue(
        probeCount: Int,
        elapsedMillis: Long,
        joined: Boolean,
        ending: Boolean,
        destroyed: Boolean,
    ): Boolean =
        !joined &&
            !ending &&
            !destroyed &&
            probeCount < maxProbes &&
            elapsedMillis < maxDurationMillis
}

internal enum class FaceTimeWebEndReason {
    EXPLICIT_LEAVE,
    RENDERER_GONE,
}

internal enum class FaceTimeLifecycleEndTrigger {
    NATIVE_END,
    BACK,
    TASK_REMOVAL,
    RENDERER_GONE,
    UNEXPECTED_DESTROY,
    EXPLICIT_WEB_LEAVE,
    INCOMING_REJECT,
}

internal enum class FaceTimeRemoteEndAction {
    /** The existing Apple web control owns the remote leave side effect. */
    WEB_LEAVE,

    /** The native APN bridge can safely decline an unanswered incoming call. */
    NATIVE_DECLINE,

    /** The explicit Apple web Leave control already sent the remote effect. */
    ALREADY_SENT,

    /** Ask the live Dart engine to invoke the typed Rust cancel_session API. */
    DART_CANCEL,
}

internal data class FaceTimeLifecycleEndSnapshot(
    val activeCall: Boolean,
    val currentActivity: Boolean,
    val changingConfigurations: Boolean,
    val inPictureInPicture: Boolean,
    val incomingCall: Boolean,
    val answered: Boolean,
    val rendererAvailable: Boolean,
)

/**
 * Owns terminal-call arbitration for one Activity instance.
 *
 * A terminal event is consumed once. Configuration changes, picture-in-picture
 * transitions, and destruction of a replaced Activity are not terminal and do
 * not consume the gate. Unanswered incoming calls use the native decline path.
 * Answered/outgoing calls use Apple's web Leave control while its renderer is
 * available. If that renderer has died, the existing Flutter/Rust bridge owns
 * cancellation instead of misusing the native incoming-decline operation.
 */
internal class FaceTimeLifecycleEndPolicy {
    private var consumed = false

    val hasConsumedTerminalEvent: Boolean
        get() = consumed

    fun consume(
        trigger: FaceTimeLifecycleEndTrigger,
        snapshot: FaceTimeLifecycleEndSnapshot,
    ): FaceTimeRemoteEndAction? {
        val isDestructionSignal =
            trigger == FaceTimeLifecycleEndTrigger.TASK_REMOVAL ||
                trigger == FaceTimeLifecycleEndTrigger.UNEXPECTED_DESTROY
        if (
            consumed ||
            !snapshot.activeCall ||
            !snapshot.currentActivity ||
            (isDestructionSignal &&
                (snapshot.changingConfigurations || snapshot.inPictureInPicture))
        ) {
            return null
        }

        consumed = true
        if (trigger == FaceTimeLifecycleEndTrigger.EXPLICIT_WEB_LEAVE) {
            return FaceTimeRemoteEndAction.ALREADY_SENT
        }
        if (!snapshot.answered && snapshot.incomingCall) {
            return FaceTimeRemoteEndAction.NATIVE_DECLINE
        }
        return if (snapshot.rendererAvailable) {
            FaceTimeRemoteEndAction.WEB_LEAVE
        } else {
            FaceTimeRemoteEndAction.DART_CANCEL
        }
    }
}

internal class FaceTimeJoinPolicy(
    private val manualRecoveryAttempt: Int = 20,
    private val maxAttempts: Int = 80,
) {
    private val previousInboundMediaBytes = mutableMapOf<Int, Long>()

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
        val evidence = FaceTimeJoinEvidenceParser.parse(rawResult)
        val outcome = evidence?.outcome ?: parseOutcome(rawResult)
        if (outcome == FaceTimeJoinOutcome.CLICKED || outcome == FaceTimeJoinOutcome.ALREADY_JOINED) {
            admissionRequested = true
        }

        return decision(outcome)
    }

    fun recordMediaEvidence(evidence: FaceTimeMediaEvidence): FaceTimeJoinDecision {
        // Once joined, transient stats failures, an ICE replacement, or an
        // idle media interval must never take the user back to Connecting.
        if (joined) return decision(FaceTimeJoinOutcome.MEDIA_CONNECTED)

        var mediaIsAdvancing = false
        val usablePeerIds = mutableSetOf<Int>()
        evidence.peerSamples().forEach { sample ->
            val peerId = sample.peerId
            val bytes = sample.mediaBytes
            if (!sample.isUsable || peerId == null || bytes == null) return@forEach
            usablePeerIds += peerId
            val previousBytes = previousInboundMediaBytes[peerId]
            if (previousBytes != null && bytes > previousBytes) {
                mediaIsAdvancing = true
            }
            previousInboundMediaBytes[peerId] = bytes
        }
        // A replaced/closed peer may not donate an old baseline to a new one.
        previousInboundMediaBytes.keys.retainAll(usablePeerIds)

        if (mediaIsAdvancing) {
            joined = true
            completedJoin = true
            return decision(FaceTimeJoinOutcome.MEDIA_CONNECTED)
        }

        val outcome = if (evidence.iceState == FaceTimeIceState.FAILED) {
            FaceTimeJoinOutcome.MEDIA_FAILED
        } else {
            FaceTimeJoinOutcome.MEDIA_PENDING
        }
        return decision(outcome)
    }

    fun reset() {
        attempts = 0
        admissionRequested = false
        joined = false
        completedJoin = false
        previousInboundMediaBytes.clear()
    }

    private fun decision(outcome: FaceTimeJoinOutcome): FaceTimeJoinDecision = FaceTimeJoinDecision(
        outcome = outcome,
        joined = joined,
        revealManualRecovery = joined || attempts >= manualRecoveryAttempt,
        retry = !joined && !completedJoin && attempts < maxAttempts,
    )

    companion object {
        fun parseOutcome(rawResult: String?): FaceTimeJoinOutcome = when (
            rawResult
                ?.trim()
                ?.removeSurrounding("\"")
                ?.lowercase()
        ) {
            "clicked" -> FaceTimeJoinOutcome.CLICKED
            "already-joined" -> FaceTimeJoinOutcome.ALREADY_JOINED
            "missing" -> FaceTimeJoinOutcome.MISSING
            "disabled" -> FaceTimeJoinOutcome.DISABLED
            "hidden" -> FaceTimeJoinOutcome.HIDDEN
            else -> FaceTimeJoinOutcome.UNKNOWN
        }
    }
}

/** Keeps the admission retry control usable after a false/error result. */
internal class FaceTimeAdmissionRetryState {
    var inFlight: Boolean = false
        private set
    var succeeded: Boolean = false
        private set

    fun begin(): Boolean {
        if (inFlight || succeeded) return false
        inFlight = true
        return true
    }

    fun complete(success: Boolean) {
        inFlight = false
        succeeded = success
    }
}

/** Ensures every activity instance reports its own matching local end once. */
internal class FaceTimeLocalEndReporter {
    private var reported = false

    fun consume(callUuid: String?): String? {
        if (reported || callUuid.isNullOrBlank()) return null
        reported = true
        return callUuid
    }
}
