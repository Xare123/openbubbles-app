package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CachedWebviewTest {
    @Test
    fun `main bundle detection accepts cache busted urls but not lookalikes`() {
        assertTrue(CachedWebview.isMainBundleUrl("https://facetime.apple.com/assets/main.js?v=42"))
        assertTrue(CachedWebview.isMainBundleUrl("https://statici.icloud.com/assets/MAIN.JS#rev"))
        assertFalse(CachedWebview.isMainBundleUrl("https://example.invalid/assets/main.js"))
        assertFalse(CachedWebview.isMainBundleUrl("https://facetime.apple.com/assets/main.js.map"))
        assertFalse(CachedWebview.isMainBundleUrl("https://facetime.apple.com/assets/not-main.jsx"))
        assertFalse(CachedWebview.isMainBundleUrl("https://facetime.apple.com/assets/main.js/"))
        assertFalse(CachedWebview.isMainBundleUrl("https://facetime.apple.com/assets/?file=main.js"))
    }

    @Test
    fun `trusted FaceTime origins require https and exact domain boundaries`() {
        assertTrue(CachedWebview.isTrustedFaceTimePageUrl("https://facetime.apple.com/join#token"))
        assertTrue(CachedWebview.isTrustedFaceTimeResourceUrl("https://cdn.apple.com/main.js"))
        assertTrue(CachedWebview.isTrustedFaceTimeResourceUrl("https://statici.icloud.com/main.js"))
        assertFalse(CachedWebview.isTrustedFaceTimePageUrl("http://facetime.apple.com/join"))
        assertFalse(CachedWebview.isTrustedFaceTimePageUrl("https://facetime.apple.com.evil.invalid/join"))
        assertFalse(CachedWebview.isTrustedFaceTimePageUrl("https://user@facetime.apple.com/join"))
        assertFalse(CachedWebview.isTrustedFaceTimeResourceUrl("https://notapple.com/main.js"))
        assertFalse(CachedWebview.isTrustedFaceTimeResourceUrl("https://apple.com.evil.invalid/main.js"))
    }

    @Test
    fun `javascript string literal escapes injection characters and line separators`() {
        val value = "A\"B\\C\nD\rE\u2028F\u2029G\u0000H"

        assertEquals(
            "\"A\\\"B\\\\C\\nD\\rE\\u2028F\\u2029G\\u0000H\"",
            CachedWebview.javascriptStringLiteral(value),
        )
    }

    @Test
    fun `javascript string literal preserves ordinary unicode`() {
        assertEquals("\"Rami 👋 مرحبًا\"", CachedWebview.javascriptStringLiteral("Rami 👋 مرحبًا"))
    }
}
