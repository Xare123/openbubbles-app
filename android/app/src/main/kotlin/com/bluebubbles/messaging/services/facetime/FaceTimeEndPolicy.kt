package com.bluebubbles.messaging.services.facetime

/** A web lifecycle notification is not authority to end a native call. */
internal class FaceTimeEndPolicy {
    private var requested = false
    private var finished = false

    fun request(): Boolean {
        if (finished || requested) return false
        requested = true
        return true
    }

    fun confirm(): Boolean {
        if (finished || !requested) return false
        finished = true
        return true
    }

    fun dispose() {
        finished = true
    }
}
