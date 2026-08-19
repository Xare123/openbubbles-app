package com.bluebubbles.messaging.services.facetime

import android.content.pm.ServiceInfo
import java.net.URI

internal fun secureWebOrigin(url: String): URI? = runCatching {
    val uri = URI(url)
    if (!uri.scheme.equals("https", ignoreCase = true) || uri.host.isNullOrBlank()) {
        return null
    }
    URI(uri.scheme.lowercase(), null, uri.host.lowercase(), uri.port, null, null, null)
}.getOrNull()

internal fun matchesWebOrigin(origin: URI?, candidate: String): Boolean {
    if (origin == null) return false
    return runCatching {
        val uri = URI(candidate)
        uri.scheme.equals(origin.scheme, ignoreCase = true) &&
            uri.host.equals(origin.host, ignoreCase = true) &&
            effectivePort(uri) == effectivePort(origin)
    }.getOrDefault(false)
}

private fun effectivePort(uri: URI): Int = when {
    uri.port >= 0 -> uri.port
    uri.scheme.equals("https", ignoreCase = true) -> 443
    else -> -1
}

internal fun javascriptStringLiteral(value: String): String = buildString {
    append('"')
    value.forEach { character ->
        when (character) {
            '\\' -> append("\\\\")
            '"' -> append("\\\"")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            '\b' -> append("\\b")
            '\u000C' -> append("\\f")
            '\u2028' -> append("\\u2028")
            '\u2029' -> append("\\u2029")
            else -> if (character.code < 0x20) {
                append("\\u%04x".format(character.code))
            } else {
                append(character)
            }
        }
    }
    append('"')
}

internal enum class FaceTimePermissionDecision {
    GRANT,
    DENY,
    WAIT,
}

internal fun faceTimePermissionDecision(
    requiredPermissions: Set<String>,
    grantedPermissions: Set<String>,
    deniedPermissions: Set<String>,
): FaceTimePermissionDecision = when {
    requiredPermissions.isEmpty() -> FaceTimePermissionDecision.DENY
    requiredPermissions.all(grantedPermissions::contains) -> FaceTimePermissionDecision.GRANT
    requiredPermissions.any(deniedPermissions::contains) -> FaceTimePermissionDecision.DENY
    else -> FaceTimePermissionDecision.WAIT
}

internal fun faceTimeForegroundServiceType(
    hasCameraPermission: Boolean,
    hasMicrophonePermission: Boolean,
): Int {
    var type = 0
    if (hasCameraPermission) {
        type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
    }
    if (hasMicrophonePermission) {
        type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    }
    return type
}
