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
    val remoteParticipantCount: Int? = null,
) {
    val hasRemoteTrack: Boolean
        get() = remoteAudioTracks > 0 || remoteVideoTracks > 0

    val hasConnectedIce: Boolean
        get() = iceState == FaceTimeIceState.CONNECTED || iceState == FaceTimeIceState.COMPLETED

    val hasRemoteParticipant: Boolean
        get() = webLeaveVisible && (remoteParticipantCount ?: 0) > 0

    val hasRemoteMedia: Boolean
        get() = hasConnectedIce && peerId != null && hasRemoteTrack && (mediaBytes ?: 0) > 0
}

internal data class FaceTimeJoinDecision(
    val outcome: FaceTimeJoinOutcome,
    val joined: Boolean,
    val revealManualRecovery: Boolean,
    val retry: Boolean,
)

internal object FaceTimeConnectionProbePolicy {
    const val maxProbes = 12
    const val initialDelayMillis = 500L
    const val pendingDelayMillis = 1500L
    const val connectedDelayMillis = 5000L
}

internal class FaceTimeJoinPolicy(
    private val manualRecoveryAttempt: Int = 20,
    private val maxAttempts: Int = 80,
) {
    private var previousPeerId: Int? = null
    private var previousInboundMediaBytes: Long? = null

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

        // A click and a visible Leave button are only signaling evidence. A
        // participant count is accepted only when the web call is visibly in
        // its joined state, and media is verified separately below.
        if (evidence?.hasRemoteParticipant == true) {
            joined = true
            completedJoin = true
        }
        return decision(outcome)
    }

    fun recordMediaEvidence(evidence: FaceTimeMediaEvidence): FaceTimeJoinDecision {
        val currentBytes = evidence.mediaBytes
        val previousBytes = previousInboundMediaBytes
        val currentPeerId = evidence.peerId
        val validBaseline = evidence.hasRemoteMedia && currentBytes != null
        val mediaIsAdvancing = validBaseline &&
            previousPeerId == currentPeerId &&
            previousBytes != null &&
            currentBytes > previousBytes

        previousPeerId = if (validBaseline) currentPeerId else null
        previousInboundMediaBytes = if (validBaseline) currentBytes else null

        if (evidence.hasRemoteParticipant || mediaIsAdvancing) {
            joined = true
            completedJoin = true
            return decision(FaceTimeJoinOutcome.MEDIA_CONNECTED)
        }

        joined = false
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
        previousPeerId = null
        previousInboundMediaBytes = null
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
