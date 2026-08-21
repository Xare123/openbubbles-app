package com.bluebubbles.messaging.services.facetime

internal data class FaceTimeWebPatchResult(
    val script: String,
    val waitingMatches: Int,
    val bannerMatches: Int,
    val submitNameMatches: Int,
    val automaticJoinCompatible: Boolean,
)

internal object FaceTimeWebCompatibility {
    private val waitingPattern = """"GenericToast\.Waiting": *"Waiting to be let in…",""".toRegex()
    private val bannerPattern = """"SessionBanner\.FaceTime": *"FaceTime Call",""".toRegex()
    private val submitNamePattern = "(submitName: *([a-zA-Z]+?)[ a-zA-Z,}=:]*?;)".toRegex()

    fun patchMainScript(script: String, name: String?, description: String): FaceTimeWebPatchResult {
        val waitingMatches = waitingPattern.findAll(script).count()
        val bannerMatches = bannerPattern.findAll(script).count()
        val submitNameMatches = if (name == null) 0 else submitNamePattern.findAll(script).count()

        var patched = script
            .replace(waitingPattern) { """"GenericToast.Waiting":"Connecting…",""" }
            .replace(bannerPattern) {
                """"SessionBanner.FaceTime":${javascriptStringLiteral(description)},"""
            }

        if (name != null) {
            patched = submitNamePattern.replace(patched) { match ->
                "${match.groupValues[1]} ${match.groupValues[2]}(${javascriptStringLiteral(name)}).then(() => Native.mirrored());"
            }
        }

        return FaceTimeWebPatchResult(
            script = patched,
            waitingMatches = waitingMatches,
            bannerMatches = bannerMatches,
            submitNameMatches = submitNameMatches,
            automaticJoinCompatible = name == null || submitNameMatches > 0,
        )
    }
}
