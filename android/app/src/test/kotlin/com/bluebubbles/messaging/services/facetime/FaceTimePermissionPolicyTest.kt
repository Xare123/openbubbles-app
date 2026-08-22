package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimePermissionPolicyTest {
    @Test
    fun startsServiceOnlyWhenEveryRequestedPermissionIsGranted() {
        assertTrue(FaceTimePermissionPolicy.shouldStartInCallService(2, intArrayOf(0, 0)))
        assertTrue(FaceTimePermissionPolicy.shouldStartInCallService(1, intArrayOf(0)))
    }

    @Test
    fun denialPartialGrantEmptyAndMismatchedResultsDoNotStartService() {
        assertFalse(FaceTimePermissionPolicy.shouldStartInCallService(2, intArrayOf(0, -1)))
        assertFalse(FaceTimePermissionPolicy.shouldStartInCallService(2, intArrayOf(-1, 0)))
        assertFalse(FaceTimePermissionPolicy.shouldStartInCallService(2, intArrayOf(0)))
        assertFalse(FaceTimePermissionPolicy.shouldStartInCallService(2, intArrayOf()))
        assertFalse(FaceTimePermissionPolicy.shouldStartInCallService(0, intArrayOf()))
    }

    @Test
    fun permissionLookupRejectsMissingAndOutOfRangeResults() {
        val results = intArrayOf(0, -1)

        assertTrue(FaceTimePermissionPolicy.isGranted(results, 0))
        assertFalse(FaceTimePermissionPolicy.isGranted(results, 1))
        assertFalse(FaceTimePermissionPolicy.isGranted(results, -1))
        assertFalse(FaceTimePermissionPolicy.isGranted(results, 2))
    }
}
