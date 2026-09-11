package com.bluebubbles.messaging.services.facetime

/** Presentation only. These insets never affect call or WebView lifecycle decisions. */
internal data class FaceTimeViewerPadding(val left: Int, val top: Int, val right: Int, val bottom: Int)

internal object FaceTimeViewerLayout {
    fun padding(left: Int, top: Int, right: Int, bottom: Int, imeBottom: Int, inPictureInPicture: Boolean): FaceTimeViewerPadding =
        if (inPictureInPicture) FaceTimeViewerPadding(0, 0, 0, 0)
        else FaceTimeViewerPadding(left.coerceAtLeast(0), top.coerceAtLeast(0), right.coerceAtLeast(0),
            maxOf(0, bottom, imeBottom))
}
