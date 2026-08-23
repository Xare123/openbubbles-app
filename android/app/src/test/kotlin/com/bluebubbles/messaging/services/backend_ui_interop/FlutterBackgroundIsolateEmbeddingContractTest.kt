package com.bluebubbles.messaging.services.backend_ui_interop

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FlutterBackgroundIsolateEmbeddingContractTest {
    private val sourceRoot = locateSourceRoot()

    @Test
    fun `background isolate paths use the current Flutter loader`() {
        for (source in backgroundIsolateSources()) {
            assertTrue(
                "${source.name} must obtain FlutterLoader from FlutterInjector",
                source.text.contains("FlutterInjector.instance().flutterLoader()"),
            )
            assertOrdered(
                source,
                "flutterLoader.startInitialization(",
                "flutterLoader.ensureInitializationComplete(",
                "flutterLoader.findAppBundlePath()",
                "DartExecutor.DartCallback(",
                "executeDartCallback(callback)",
            )
        }
    }

    @Test
    fun `callback handles retain their exact shared preference keys`() {
        val worker = readSource(
            "services/backend_ui_interop/DartWorker.kt",
        )
        val nativeSync = readSource(
            "services/system/NativeSyncIsolateHandler.kt",
        )

        assertTrue(
            worker.text.contains(
                "FlutterCallbackInformation.lookupCallbackInformation(",
            ),
        )
        assertTrue(worker.text.contains("\"flutter.backgroundCallbackHandle\""))
        assertTrue(
            nativeSync.text.contains(
                "FlutterCallbackInformation.lookupCallbackInformation(",
            ),
        )
        assertTrue(nativeSync.text.contains("\"flutter.backgroundSyncIsolate\""))
        assertTrue(
            "native sync must reject a missing callback instead of hanging",
            nativeSync.text.contains(
                "?: throw IllegalStateException(\"CloudKit sync callback is unavailable\")",
            ),
        )
        assertTrue(
            "native sync startup failures must resolve the pending method call",
            nativeSync.text.contains("mainresult.error("),
        )
        assertTrue(
            "the worker exit call must be acknowledged before teardown",
            nativeSync.text.contains("result.success(null)"),
        )
        assertTrue(
            "destroyed workers must clear only their own static engine",
            nativeSync.text.contains("if (engine === workerEngine)"),
        )
        assertTrue(
            "the native start result must be completed at most once",
            nativeSync.text.contains("startResultCompleted.compareAndSet(false, true)"),
        )
    }

    @Test
    fun `background isolate sources contain no removed v1 embedding APIs`() {
        val removedApis = listOf(
            "io.flutter.view.Flutter" + "Main",
            "Flutter" + "Main.",
            "PluginRegistry." + "Registrar",
            "ShimPlugin" + "Registry",
            "Shim" + "Registrar",
        )

        for (source in backgroundIsolateSources()) {
            for (removedApi in removedApis) {
                assertFalse(
                    "${source.name} still references removed API $removedApi",
                    source.text.contains(removedApi),
                )
            }
        }
    }

    private fun backgroundIsolateSources(): List<KotlinSource> = listOf(
        readSource("services/backend_ui_interop/DartWorker.kt"),
        readSource("services/system/NativeSyncIsolateHandler.kt"),
    )

    private fun readSource(relativePath: String): KotlinSource {
        val file = File(sourceRoot, relativePath)
        assertTrue("Missing Android source file: ${file.absolutePath}", file.isFile)
        return KotlinSource(file.name, file.readText())
    }

    private fun assertOrdered(source: KotlinSource, vararg snippets: String) {
        var previousIndex = -1
        for (snippet in snippets) {
            val index = source.text.indexOf(snippet)
            assertTrue(
                "${source.name} is missing or reorders '$snippet'",
                index > previousIndex,
            )
            previousIndex = index
        }
    }

    private data class KotlinSource(
        val name: String,
        val text: String,
    )

    companion object {
        private fun locateSourceRoot(): File {
            val candidates = listOf(
                File("src/main/kotlin/com/bluebubbles/messaging"),
                File("android/app/src/main/kotlin/com/bluebubbles/messaging"),
            )
            return candidates.firstOrNull(File::isDirectory)
                ?: error(
                    "Unable to locate Android source root from " +
                        File(".").absolutePath,
                )
        }
    }
}
