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
) {
    val hasRemoteTrack: Boolean
        get() = remoteAudioTracks > 0 || remoteVideoTracks > 0

    val hasConnectedIce: Boolean
        get() = iceState == FaceTimeIceState.CONNECTED || iceState == FaceTimeIceState.COMPLETED

    val isConnected: Boolean
        get() = hasConnectedIce && hasRemoteTrack
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
    BOTTOM_LEFT,
}

internal object FaceTimeConnectionProbePolicy {
    const val maxProbes = 80
    const val initialDelayMillis = 500L
    const val pendingDelayMillis = 1500L
    const val connectedDelayMillis = 5000L
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
    fun shouldShowNativeEndControl(): Boolean = true

    fun nativeEndPlacement(webLeaveVisible: Boolean): FaceTimeNativeEndPlacement =
        if (webLeaveVisible) FaceTimeNativeEndPlacement.BOTTOM_LEFT else FaceTimeNativeEndPlacement.TOP_RIGHT
}

internal class FaceTimeJoinPolicy(
    private val manualRecoveryAttempt: Int = 20,
    private val maxAttempts: Int = 80,
) {
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
        // WebView must later report connected ICE plus a remote media track.
        return decision(outcome)
    }

    fun recordMediaEvidence(evidence: FaceTimeMediaEvidence): FaceTimeJoinDecision {
        if (evidence.isConnected) {
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
