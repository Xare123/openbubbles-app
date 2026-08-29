package com.bluebubbles.messaging.services.facetime

import android.webkit.PermissionRequest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertArrayEquals
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

    @Test
    fun webPermissionGrantDropsUnsupportedAndDuplicateResources() {
        assertArrayEquals(
            arrayOf(
                PermissionRequest.RESOURCE_VIDEO_CAPTURE,
                PermissionRequest.RESOURCE_AUDIO_CAPTURE,
            ),
            FaceTimePermissionPolicy.supportedWebResources(
                arrayOf(
                    PermissionRequest.RESOURCE_VIDEO_CAPTURE,
                    PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID,
                    PermissionRequest.RESOURCE_VIDEO_CAPTURE,
                    PermissionRequest.RESOURCE_AUDIO_CAPTURE,
                ),
                setOf(
                    PermissionRequest.RESOURCE_VIDEO_CAPTURE,
                    PermissionRequest.RESOURCE_AUDIO_CAPTURE,
                ),
            ),
        )
        assertTrue(
            FaceTimePermissionPolicy.supportedWebResources(
                arrayOf(PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID),
                setOf(
                    PermissionRequest.RESOURCE_VIDEO_CAPTURE,
                    PermissionRequest.RESOURCE_AUDIO_CAPTURE,
                ),
            ).isEmpty(),
        )
    }
}
