package com.bluebubbles.messaging.services.system

import android.app.Activity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EnableBtContractTest {
    @Test
    fun `disabled without request completes false even when a request is pending`() {
        assertEquals(
            EnableBtContract.DisabledDecision.COMPLETE_FALSE,
            EnableBtContract.decideDisabledRequest(request = false, hasPending = false),
        )
        assertEquals(
            EnableBtContract.DisabledDecision.COMPLETE_FALSE,
            EnableBtContract.decideDisabledRequest(request = false, hasPending = true),
        )
    }
    @Test
    fun `disabled with request launches prompt only when idle`() {
        assertEquals(
            EnableBtContract.DisabledDecision.LAUNCH_PROMPT,
            EnableBtContract.decideDisabledRequest(request = true, hasPending = false),
        )
    }
    @Test
    fun `second request while one is pending is rejected`() {
        assertEquals(
            EnableBtContract.DisabledDecision.REJECT_DUPLICATE,
            EnableBtContract.decideDisabledRequest(request = true, hasPending = true),
        )
    }
    @Test
    fun `missing callback resolves to null so recreation is ignored`() {
        assertNull(EnableBtContract.resolveEnableResult(pendingExists = false, resultCode = Activity.RESULT_OK))
        assertNull(EnableBtContract.resolveEnableResult(pendingExists = false, resultCode = Activity.RESULT_CANCELED))
    }
    @Test
    fun `result reports RESULT_OK only`() {
        assertTrue(EnableBtContract.mapActivityResult(Activity.RESULT_OK))
        assertFalse(EnableBtContract.mapActivityResult(Activity.RESULT_CANCELED))
        assertEquals(true, EnableBtContract.resolveEnableResult(pendingExists = true, resultCode = Activity.RESULT_OK))
        assertEquals(false, EnableBtContract.resolveEnableResult(pendingExists = true, resultCode = Activity.RESULT_CANCELED))
    }
}
