package com.bluebubbles.messaging.services.system

import android.app.Activity

object EnableBtContract {
    enum class DisabledDecision { COMPLETE_FALSE, REJECT_DUPLICATE, LAUNCH_PROMPT }

    fun decideDisabledRequest(request: Boolean, hasPending: Boolean): DisabledDecision {
        if (!request) return DisabledDecision.COMPLETE_FALSE
        if (hasPending) return DisabledDecision.REJECT_DUPLICATE
        return DisabledDecision.LAUNCH_PROMPT
    }

    fun mapActivityResult(resultCode: Int): Boolean = resultCode == Activity.RESULT_OK

    fun resolveEnableResult(pendingExists: Boolean, resultCode: Int): Boolean? {
        if (!pendingExists) return null
        return mapActivityResult(resultCode)
    }
}
