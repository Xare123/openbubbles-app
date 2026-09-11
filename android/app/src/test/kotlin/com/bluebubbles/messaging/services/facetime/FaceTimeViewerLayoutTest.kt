package com.bluebubbles.messaging.services.facetime

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Test
import org.w3c.dom.Element

class FaceTimeViewerLayoutTest {
    private val android = "http://schemas.android.com/apk/res/android"
    private fun Element.attr(name: String): String = getAttributeNS(android, name)
    private fun Element.children(): List<Element> = (0 until childNodes.length)
        .mapNotNull { childNodes.item(it) as? Element }
    private fun layout(): Element = DocumentBuilderFactory.newInstance().apply {
        isNamespaceAware = true
        setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
    }.newDocumentBuilder().parse(File("android/app/src/main/res/layout/activity_face_time.xml")).documentElement

    @Test fun portraitUsesSafeBarsAndDoesNotAddTheKeyboardTwice() {
        assertEquals(FaceTimeViewerPadding(0, 28, 0, 24),
            FaceTimeViewerLayout.padding(0, 28, 0, 24, 0, false))
        assertEquals(FaceTimeViewerPadding(0, 28, 0, 280),
            FaceTimeViewerLayout.padding(0, 28, 0, 24, 280, false))
    }

    @Test fun landscapeRespectsAsymmetricCutouts() {
        assertEquals(FaceTimeViewerPadding(44, 0, 12, 24),
            FaceTimeViewerLayout.padding(44, 0, 12, 24, 0, false))
    }

    @Test fun pictureInPictureReleasesAllNativeInsets() {
        assertEquals(FaceTimeViewerPadding(0, 0, 0, 0),
            FaceTimeViewerLayout.padding(44, 28, 12, 24, 280, true))
        assertEquals(FaceTimeViewerPadding(0, 0, 0, 0),
            FaceTimeViewerLayout.padding(-1, -1, -1, -1, -1, false))
    }

    @Test fun headerVideoAndDockAreMeasuredSiblingsNotOverlays() {
        val root = layout()
        assertEquals("@color/facetime_viewer_canvas", root.attr("background"))
        val surface = root.children().single { it.attr("id") == "@+id/viewerSurface" }
        assertEquals("LinearLayout", surface.tagName)
        assertEquals("vertical", surface.attr("orientation"))
        val regions = surface.children()
        assertEquals(listOf("@+id/callHeader", "@+id/main_frame", "@+id/nativeCallControls"),
            regions.map { it.attr("id") })
        assertEquals("wrap_content", regions[0].attr("layout_height"))
        assertEquals("0dp", regions[1].attr("layout_height"))
        assertEquals("1", regions[1].attr("layout_weight"))
        assertEquals("", regions[1].attr("fitsSystemWindows"))
        assertEquals("wrap_content", regions[2].attr("layout_height"))
        assertTrue(regions.all { it.attr("layout_marginTop").isEmpty() })
    }

    @Test fun largeTextStatusWrapsAndEndIsOneAccessibleAction() {
        val regions = layout().children().first().children()
        val header = regions[0].children()
        assertEquals(1, header.size) // Apple's existing header remains the only caller name.
        val status = header.single { it.attr("id") == "@+id/connectionStatus" }
        assertEquals("match_parent", status.attr("layout_width"))
        assertEquals("wrap_content", status.attr("layout_height"))
        assertEquals("", status.attr("maxLines"))
        assertEquals("", status.attr("ellipsize"))
        assertEquals("polite", status.attr("accessibilityLiveRegion"))
        val end = regions[2].children().single()
        assertEquals("Button", end.tagName)
        assertEquals("@+id/endCall", end.attr("id"))
        assertEquals("56dp", end.attr("minHeight"))
        assertEquals("wrap_content", end.attr("layout_height"))
        assertEquals("@string/facetime_viewer_end_description", end.attr("contentDescription"))
        assertEquals("false", end.attr("textAllCaps"))
    }

    @Test fun nativeStatusDoesNotDuplicateCallerNamingAndEndHasStateFeedback() {
        val root = layout()
        val elements = root.getElementsByTagName("*")
        val ids = (0 until elements.length).map { (elements.item(it) as Element).attr("id") }
            .filter { it.isNotEmpty() }
        assertEquals(ids.size, ids.distinct().size)
        assertEquals(1, ids.count { it == "@+id/endCall" })
        assertFalse(ids.contains("@+id/viewerTitle"))
        val source = File("android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt").readText()
        assertTrue(source.contains("binding.connectionStatus.visibility == View.VISIBLE"))
        val endDrawable = File("android/app/src/main/res/drawable/facetime_viewer_end.xml").readText()
        assertTrue(endDrawable.contains("<ripple"))
        assertTrue(endDrawable.contains("android:state_enabled=\"false\""))
        assertTrue(endDrawable.contains("#66FF3B30"))
    }
}
