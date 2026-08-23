package com.bluebubbles.messaging.services.facetime

import org.junit.Assert.assertEquals
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
}
