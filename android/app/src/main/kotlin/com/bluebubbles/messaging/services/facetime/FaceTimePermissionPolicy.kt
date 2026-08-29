package com.bluebubbles.messaging.services.facetime

/** Pure decision logic for starting the FaceTime in-call foreground service. */
internal object FaceTimePermissionPolicy {
    private const val grantedResult = 0

    fun isGranted(grantResults: IntArray, index: Int): Boolean =
        index >= 0 && grantResults.getOrNull(index) == grantedResult

    fun shouldStartInCallService(permissionCount: Int, grantResults: IntArray): Boolean =
        permissionCount > 0 &&
            permissionCount == grantResults.size &&
            grantResults.all { it == grantedResult }

    fun supportedWebResources(
        requestedResources: Array<String>,
        supportedResources: Set<String>,
    ): Array<String> = requestedResources
        .filter(supportedResources::contains)
        .distinct()
        .toTypedArray()
}
