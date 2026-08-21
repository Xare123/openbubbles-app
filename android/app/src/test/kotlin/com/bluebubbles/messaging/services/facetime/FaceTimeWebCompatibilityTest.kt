package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeWebCompatibilityTest {
    private val representativeMainScript = """
        const strings={"GenericToast.Waiting": "Waiting to be let in…","SessionBanner.FaceTime": "FaceTime Call",};
        const flow={submitName: submitGuestName, handler: submitGuestName};
    """.trimIndent()

    @Test
    fun representativeAppleScriptRemainsPatchableForAutomaticJoin() {
        val result = FaceTimeWebCompatibility.patchMainScript(
            representativeMainScript,
            "Guest",
            "FaceTime Video Call",
        )

        assertTrue(result.automaticJoinCompatible)
        assertEquals(1, result.waitingMatches)
        assertEquals(1, result.bannerMatches)
        assertEquals(1, result.submitNameMatches)
        assertTrue(result.script.contains("Connecting…"))
        assertTrue(result.script.contains("Native.mirrored()"))
        assertTrue(result.script.contains("FaceTime Video Call"))
    }

    @Test
    fun appleScriptDriftFailsPreflightInsteadOfPretendingAutoJoinWillWork() {
        val drifted = "const flow={registerGuest: renamedFunction};"

        val result = FaceTimeWebCompatibility.patchMainScript(
            drifted,
            "Guest",
            "FaceTime Video Call",
        )

        assertFalse(result.automaticJoinCompatible)
        assertEquals(0, result.submitNameMatches)
        assertEquals(drifted, result.script)
    }

    @Test
    fun anonymousPreloadDoesNotRequireSubmitNamePatch() {
        val result = FaceTimeWebCompatibility.patchMainScript(
            "const untouched=true;",
            null,
            "FaceTime Call",
        )

        assertTrue(result.automaticJoinCompatible)
    }

    @Test
    fun replacementTreatsDollarSignsInGuestNameAsText() {
        val result = FaceTimeWebCompatibility.patchMainScript(
            representativeMainScript,
            "Guest\$1",
            "FaceTime Call",
        )

        assertTrue(result.automaticJoinCompatible)
        assertTrue(result.script.contains("Guest\$1"))
    }
}
