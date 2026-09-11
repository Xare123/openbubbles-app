package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class FaceTimeEndPolicyTest {
    @Test
    fun `duplicate lifecycle notifications before a request cannot close a call`() {
        val policy = FaceTimeEndPolicy()
        repeat(3) { assertFalse(policy.confirm()) }
        assertTrue(policy.request())
        assertFalse(policy.request())
        assertTrue(policy.confirm())
        assertFalse(policy.confirm())
    }

    @Test
    fun `teardown rejects queued request and confirmation callbacks`() {
        val beforeRequest = FaceTimeEndPolicy()
        beforeRequest.dispose()
        assertFalse(beforeRequest.request())
        assertFalse(beforeRequest.confirm())

        val awaitingConfirmation = FaceTimeEndPolicy()
        assertTrue(awaitingConfirmation.request())
        awaitingConfirmation.dispose()
        assertFalse(awaitingConfirmation.confirm())
        assertFalse(awaitingConfirmation.request())
    }

    @Test
    fun `a later call has independent end state`() {
        val oldCall = FaceTimeEndPolicy()
        assertTrue(oldCall.request())
        oldCall.dispose()
        val nextCall = FaceTimeEndPolicy()
        assertFalse(oldCall.confirm())
        assertTrue(nextCall.request())
        assertTrue(nextCall.confirm())
    }

    @Test
    fun `callbacks queued before teardown cannot close the next activity`() {
        val policy = FaceTimeEndPolicy()
        var closeCount = 0
        val queuedRequest = { policy.request() }
        val queuedConfirmation = { if (policy.confirm()) closeCount++ }
        policy.dispose()
        queuedRequest()
        queuedConfirmation()
        assertEquals(0, closeCount)
    }

}
