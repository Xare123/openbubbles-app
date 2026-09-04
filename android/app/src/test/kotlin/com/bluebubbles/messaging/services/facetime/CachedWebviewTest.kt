package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CachedWebviewTest {
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

    @Test
    fun `isMainJsUrl intercepts exact main js`() {
        assertTrue(CachedWebview.isMainJsUrl("https://example.com/static/main.js"))
    }

    @Test
    fun `isMainJsUrl intercepts query and fragment suffixes`() {
        assertTrue(CachedWebview.isMainJsUrl("https://example.com/static/main.js?v=123"))
        assertTrue(CachedWebview.isMainJsUrl("https://example.com/static/main.js#section"))
        assertTrue(CachedWebview.isMainJsUrl("https://example.com/static/main.js?v=123#section"))
    }

    @Test
    fun `isMainJsUrl leaves hashed and unrelated scripts untouched`() {
        assertFalse(CachedWebview.isMainJsUrl("https://example.com/static/main.abc123.js"))
        assertFalse(CachedWebview.isMainJsUrl("https://example.com/static/main.js.map"))
        assertFalse(CachedWebview.isMainJsUrl("https://example.com/static/other.js?v=1"))
        assertFalse(CachedWebview.isMainJsUrl("https://example.com/static/nomain.js"))
        assertFalse(CachedWebview.isMainJsUrl(null))
        assertFalse(CachedWebview.isMainJsUrl(""))
    }
}
