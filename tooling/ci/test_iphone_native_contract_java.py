"""Source-contract checks for the three bounded Java corrections.

These tests intentionally do not claim Java compilation or Ghidra runtime
behavior. The parent Mac lane owns compiling OBNativeActivationAnalysis.java
against Ghidra 12.1.4 and running it on the synthetic CFSTR fixture. The
Python scan model below is only an algebra check for the intended chunk
carry algorithm; the Java assertions pin the corresponding source shape.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent
JAVA = ROOT / "ghidra_scripts" / "OBNativeActivationAnalysis.java"


def segment(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def scan_positions(data, needle, chunk_size=65536):
    """Mirror the corrected carry algorithm to check boundary algebra."""
    hits = []
    cursor = 0
    carry = b""
    remaining = len(data)
    while remaining > 0:
        want = min(chunk_size, remaining)
        chunk = data[cursor:cursor + want]
        if not chunk:
            break
        window = carry + chunk
        base = cursor - len(carry)
        for offset in range(0, len(window) - len(needle) + 1):
            if window[offset:offset + len(needle)] == needle:
                hits.append(base + offset)
        carry = window[-min(len(needle) - 1, len(window)):] if len(needle) > 1 else b""
        cursor += len(chunk)
        remaining -= len(chunk)
    return hits


class JavaCorrectionContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = JAVA.read_text(encoding="utf-8")

    def test_chunk_read_starts_at_cursor_while_carry_stays_at_buffer_start(self):
        body = segment(self.source, "private List<Long> findAsciiString",
                       "private Set<Long> findPointerHolders")
        self.assertIn("memory.getBytes(addr(cursor), buffer, carry, want)", body)
        self.assertNotIn("memory.getBytes(addr(cursor - carry)", body)
        self.assertIn("hits.add(cursor - carry + i)", body)
        self.assertIn("System.arraycopy(buffer, total - carry, buffer, 0, carry)", body)

    def test_corrected_carry_algebra_finds_boundary_and_interior_needles(self):
        needle = b"FairPlaySignature"
        block = bytearray(b"A" * 131072)
        for position in (0, 65519, 65536, 70000, len(block) - len(needle)):
            block[position:position + len(needle)] = needle
        self.assertEqual(
            scan_positions(bytes(block), needle),
            [0, 65519, 65536, 70000, len(block) - len(needle)],
        )
        crossing = bytearray(b"A" * 131072)
        crossing[65528:65528 + len(needle)] = needle
        self.assertEqual(scan_positions(bytes(crossing), needle), [65528])

    def test_cfstring_normalization_uses_struct_base_not_pointer_field(self):
        body = segment(self.source, "private long normalizeCfStringBase",
                       "private void collectSymbols")
        for anchor in (
            "holder - CFSTRING_STRING_POINTER_OFFSET",
            "memory.getLong(stringPointerAddress)",
            "base + CFSTRING_LENGTH_OFFSET",
            "getDataContaining(baseAddress)",
            "data.getMinAddress().getOffset() == base",
            'lowered.contains("cfstring")',
            "stringTargets.contains(actualTarget)",
        ):
            self.assertIn(anchor, body)
        self.assertLess(body.index("if (length < seedBytes) return -1;"),
                        body.index("if (typedCfString) return base;"))
        self.assertLess(body.index("if (typedCfString) return base;"),
                        body.index("if (length != seedBytes) return -1;"))

    def test_cfstring_bases_are_expanded_into_reference_frontier_and_exported(self):
        resolve = segment(self.source, "private void resolveSeed",
                          "private long normalizeCfStringBase")
        self.assertIn("normalizeCfStringBase(holder, seed, stringTargets)", resolve)
        self.assertIn("expanded.add(base)", resolve)
        self.assertIn("result.cfStringBases.add(hex(base))", resolve)
        self.assertIn("cfstring_bases", self.source)
        self.assertIn("cfstring_base_count", self.source)
        refs = segment(self.source, "private void collectReferences",
                       "private Candidate candidateFor")
        self.assertIn('"->" + hex(target)', refs)

    def test_decompile_bound_counts_attempts_not_only_successes(self):
        body = segment(self.source, "private int decompileSelected",
                       "private List<Long> findAsciiString")
        self.assertIn("decompileAttempts = 0;", body)
        self.assertIn("if (decompileAttempts >= MAX_DECOMPILE_ATTEMPTS) break;", body)
        self.assertNotIn("if (done >= MAX_DECOMPILED) break;", body)
        self.assertLess(body.index("decompileAttempts++;"),
                        body.index("decompiler.decompileFunction"))
        self.assertLess(body.index("decompiler.decompileFunction"),
                        body.index("done++;"))
        self.assertIn("decompile_attempts", self.source)
        self.assertIn("max_decompile_attempts", self.source)

    def test_headless_timeout_surface_is_retained(self):
        self.assertIn("extends HeadlessScript", self.source)
        self.assertIn("analysisTimeoutOccurred()", self.source)

    def test_decompiler_startup_and_candidate_errors_are_bounded_and_exported(self):
        body = segment(self.source, "private int decompileSelected",
                       "private List<Long> findAsciiString")
        self.assertIn("boundedDiagnostic(decompiler.getLastMessage())", body)
        self.assertIn("boundedDiagnostic(results.getErrorMessage())", body)
        self.assertIn("decompilerOpened = true;", body)
        self.assertIn("MAX_DIAGNOSTIC_CHARS = 1024", self.source)
        for field in ("decompiler_opened", "decompiler_message", "decompile_error"):
            self.assertIn(field, self.source)

    def test_owner_followup_is_only_two_real_observed_native_callees(self):
        body = segment(self.source, "private void collectObservedOwnerTargets",
                       "private void resolveSeed")
        self.assertIn("0x1000056b4L", body)
        self.assertIn("0x10005c4e4L", body)
        self.assertIn("function.isExternal() || function.isThunk()", body)
        self.assertIn('"mobileactivationd".equals(currentProgram.getName())', self.source)
        self.assertIn('"csr-key-owner".equals(args[1])', self.source)
        self.assertIn('"analysis_scope"', self.source)
        self.assertNotIn("findAsciiString", body)


if __name__ == "__main__":
    unittest.main()
