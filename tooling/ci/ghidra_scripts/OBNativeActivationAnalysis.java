// Bounded static seed-to-function analysis for one already-identified
// mobileactivationd. Runs only as a Ghidra headless postScript and writes a
// small JSON evidence file. It executes nothing from the target, exports no
// binary bytes, and proves no runtime, caller-access or CSR behaviour.
//
// Argument 1 (required): absolute output JSON path inside owned work.
// @category OpenBubbles.Activation
// @runtime Java

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.util.headless.HeadlessScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryAccessException;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

public class OBNativeActivationAnalysis extends HeadlessScript {

    private static final int MAX_SEED_ADDRESSES = 64;
    private static final int MAX_NODES_PER_LEVEL = 256;
    private static final int MAX_TOTAL_NODES = 1024;
    private static final int MAX_CANDIDATES_EXPORTED = 64;
    private static final int MAX_REFERENCES_PER_CANDIDATE = 8;
    private static final int MAX_CALLS_PER_CANDIDATE = 64;
    private static final int MAX_INSTRUCTIONS_PER_CANDIDATE = 20000;
    private static final int MAX_DECOMPILE_ATTEMPTS = 8;
    private static final int DECOMPILE_TIMEOUT_SECONDS = 30;
    private static final int MAX_PSEUDOCODE_CHARS = 20000;
    private static final int MAX_DIAGNOSTIC_CHARS = 1024;
    private static final int CFSTRING_STRING_POINTER_OFFSET = 16;
    private static final int CFSTRING_LENGTH_OFFSET = 24;
    private static final int MAX_CFSTRING_BASES_EXPORTED = 16;

    private static final class Seed {
        final String text;
        final String kind;
        final int weight;
        final boolean substringSymbolMatch;

        Seed(String text, String kind, int weight, boolean substringSymbolMatch) {
            this.text = text;
            this.kind = kind;
            this.weight = weight;
            this.substringSymbolMatch = substringSymbolMatch;
        }
    }

    // Signer and CSR producers outrank activation context. Certificate
    // handler names are context only; the reviewed RK/UIK region is kept
    // listed but excluded from decompilation selection below.
    private static final Seed[] SEEDS = {
        new Seed("FairPlaySignature", "dictionary-key", 50, false),
        new Seed("FairPlayCertChain", "dictionary-key", 50, false),
        new Seed("createActivationInfo", "method-name", 45, true),
        new Seed("createTunnel1ActivationInfo", "method-name", 45, true),
        new Seed("ActivationInfoXML", "dictionary-key", 40, false),
        new Seed("DeviceCertRequest", "dictionary-key", 25, false),
        new Seed("ClientCertificateRequest", "dictionary-key", 25, false),
        new Seed("CreateActivationInfoRequest", "diagnostic-string", 15, false),
        new Seed("CreateTunnel1ActivationInfoRequest", "diagnostic-string", 15, false),
        new Seed("CreateTunnel1SessionInfoRequest", "diagnostic-string", 10, false),
        new Seed("ActivationRequestInfo", "diagnostic-string", 10, false),
        new Seed("handleActivationInfo", "method-name", 10, true),
    };

    private static final class SeedResult {
        Seed seed;
        final List<String> stringAddresses = new ArrayList<>();
        int stringAddressCount;
        boolean stringTruncated;
        final List<String> cfStringBases = new ArrayList<>();
        final Set<Long> cfStringBaseOffsets = new LinkedHashSet<>();
        boolean cfStringBasesTruncated;
        final List<String[]> symbolHits = new ArrayList<>(); // name, address, hasBody
        final Set<Long> candidateEntries = new LinkedHashSet<>();
    }

    private static final class Candidate {
        long entry;
        String name = "";
        long bodyAddresses;
        boolean external;
        boolean thunk;
        int score;
        final Set<String> seeds = new LinkedHashSet<>();
        final Map<String, Integer> seedWeights = new LinkedHashMap<>();
        final List<String> references = new ArrayList<>();
        int referenceCount;
        List<String> calls;
        boolean callsTruncated;
        String pseudocode;
        boolean pseudocodeTruncated;
        String decompileExclusion;
        String decompileError;
    }

    private final List<String> truncations = new ArrayList<>();
    private int decompileAttempts;
    private boolean decompilerOpened;
    private String decompilerMessage;

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args == null || args.length != 1 || args[0].isEmpty()) {
            throw new IllegalArgumentException("exactly-one-output-json-required");
        }
        File output = new File(args[0]);
        if (!output.isAbsolute()) {
            throw new IllegalArgumentException("absolute-output-json-required");
        }

        Map<String, SeedResult> seedResults = new LinkedHashMap<>();
        Map<Long, Candidate> candidates = new LinkedHashMap<>();
        for (Seed seed : SEEDS) {
            SeedResult result = new SeedResult();
            result.seed = seed;
            resolveSeed(seed, result, candidates);
            seedResults.put(seed.text, result);
            if (monitor != null && monitor.isCancelled()) break;
        }

        List<Candidate> ordered = new ArrayList<>(candidates.values());
        for (Candidate candidate : ordered) finishCandidate(candidate);
        ordered.sort(Comparator.comparingInt((Candidate c) -> c.score).reversed()
            .thenComparingLong(c -> c.entry));
        int candidateTotal = ordered.size();
        boolean candidatesTruncated = candidateTotal > MAX_CANDIDATES_EXPORTED;
        if (candidatesTruncated) truncations.add("candidate-list");
        List<Candidate> exported = ordered.subList(0, Math.min(candidateTotal, MAX_CANDIDATES_EXPORTED));

        int callsComputed = 0;
        for (Candidate candidate : exported) {
            if (callsComputed++ < 24) collectCalls(candidate);
        }
        int decompiled = decompileSelected(exported);

        String timeout;
        try {
            timeout = analysisTimeoutOccurred() ? "true" : "false";
        } catch (Exception e) {
            timeout = "unknown";
        }

        StringBuilder json = new StringBuilder();
        json.append("{\n");
        field(json, 1, "schema", "1", true);
        field(json, 1, "tool", q("ob-native-activation-headless"), true);
        json.append(" \"program\": {");
        json.append("\"name\": ").append(q(String.valueOf(currentProgram.getName())));
        json.append(", \"image_base\": ").append(q(hex(currentProgram.getImageBase())));
        json.append(", \"language\": ").append(q(String.valueOf(currentProgram.getLanguageID())));
        json.append(", \"compiler\": ").append(q(String.valueOf(currentProgram.getCompilerSpec().getCompilerSpecID())));
        json.append("},\n");
        field(json, 1, "analysis_timeout_occurred", q(timeout), true);
        json.append(" \"limits\": {");
        json.append("\"max_candidates_exported\": ").append(MAX_CANDIDATES_EXPORTED);
        json.append(", \"max_decompile_attempts\": ").append(MAX_DECOMPILE_ATTEMPTS);
        json.append(", \"decompile_timeout_seconds\": ").append(DECOMPILE_TIMEOUT_SECONDS);
        json.append(", \"max_pseudocode_chars\": ").append(MAX_PSEUDOCODE_CHARS);
        json.append("},\n");

        json.append(" \"seeds\": [");
        boolean firstSeed = true;
        for (SeedResult result : seedResults.values()) {
            if (!firstSeed) json.append(",");
            firstSeed = false;
            json.append("{\"seed\": ").append(q(result.seed.text));
            json.append(", \"kind\": ").append(q(result.seed.kind));
            json.append(", \"string_addresses\": [");
            appendStrings(json, result.stringAddresses);
            json.append("], \"string_address_count\": ").append(result.stringAddressCount);
            json.append(", \"string_truncated\": ").append(result.stringTruncated);
            json.append(", \"cfstring_bases\": [");
            appendStrings(json, result.cfStringBases);
            json.append("], \"cfstring_base_count\": ").append(result.cfStringBaseOffsets.size());
            json.append(", \"cfstring_bases_truncated\": ").append(result.cfStringBasesTruncated);
            json.append(", \"symbol_hits\": [");
            boolean firstHit = true;
            for (String[] hit : result.symbolHits) {
                if (!firstHit) json.append(",");
                firstHit = false;
                json.append("{\"name\": ").append(q(hit[0]));
                json.append(", \"address\": ").append(q(hit[1]));
                json.append(", \"has_function_body\": ").append(hit[2]).append("}");
            }
            json.append("], \"candidate_function_count\": ").append(result.candidateEntries.size());
            json.append("}");
        }
        json.append("],\n");

        json.append(" \"candidates\": [");
        boolean firstCandidate = true;
        for (Candidate candidate : exported) {
            if (!firstCandidate) json.append(",");
            firstCandidate = false;
            json.append("{\"entry\": ").append(q(hex(candidate.entry)));
            json.append(", \"name\": ").append(q(candidate.name));
            json.append(", \"score\": ").append(candidate.score);
            json.append(", \"body_addresses\": ").append(candidate.bodyAddresses);
            json.append(", \"external\": ").append(candidate.external);
            json.append(", \"thunk\": ").append(candidate.thunk);
            json.append(", \"seeds\": [");
            appendStrings(json, new ArrayList<>(candidate.seeds));
            json.append("], \"references\": [");
            appendStrings(json, candidate.references);
            json.append("], \"reference_count\": ").append(candidate.referenceCount);
            json.append(", \"calls\": ");
            if (candidate.calls == null) json.append("null");
            else { json.append("["); appendStrings(json, candidate.calls); json.append("]"); }
            json.append(", \"calls_truncated\": ").append(candidate.callsTruncated);
            json.append(", \"decompile_exclusion\": ")
                .append(candidate.decompileExclusion == null ? "null" : q(candidate.decompileExclusion));
            json.append(", \"decompile_error\": ").append(q(candidate.decompileError));
            json.append(", \"pseudocode\": ");
            if (candidate.pseudocode == null) json.append("null");
            else {
                json.append("{\"text\": ").append(q(candidate.pseudocode));
                json.append(", \"truncated\": ").append(candidate.pseudocodeTruncated);
                json.append(", \"chars\": ").append(candidate.pseudocode.length()).append("}");
            }
            json.append("}");
        }
        json.append("],\n");
        field(json, 1, "candidate_count_total", Integer.toString(candidateTotal), true);
        field(json, 1, "candidates_truncated", Boolean.toString(candidatesTruncated), true);
        field(json, 1, "decompiler_opened", Boolean.toString(decompilerOpened), true);
        field(json, 1, "decompiler_message", q(decompilerMessage), true);
        field(json, 1, "decompile_attempts", Integer.toString(decompileAttempts), true);
        field(json, 1, "decompiled_count", Integer.toString(decompiled), true);
        json.append(" \"truncations\": [");
        appendStrings(json, truncations);
        json.append("],\n");
        json.append(" \"unknowns\": [");
        appendStrings(json, Arrays.asList(
            "static candidates do not prove runtime reachability, caller access, entitlements, input acceptance or an accepted CSR",
            "Objective-C relative method lists are not decoded; method-name seeds resolve only through symbols or code and data references",
            "CFString bases are accepted only from typed Ghidra Data or an exact 32-byte structural check; structural normalization remains an inference",
            "dyld chained-fixup encodings beyond references and pointer values materialised by the loader are not decoded",
            "pseudocode is decompiler inference over static code, not original source or observed execution"));
        json.append("]\n}\n");

        try (OutputStreamWriter writer = new OutputStreamWriter(new FileOutputStream(output), StandardCharsets.UTF_8)) {
            writer.write(json.toString());
        }
    }

    private void resolveSeed(Seed seed, SeedResult result, Map<Long, Candidate> candidates) {
        Set<Long> nodes = new LinkedHashSet<>();
        collectSymbols(seed, result, nodes, candidates);
        List<Long> stringHits = findAsciiString(seed.text);
        Set<Long> stringTargets = new LinkedHashSet<>(stringHits);
        result.stringAddressCount = stringHits.size();
        result.stringTruncated = stringHits.size() > MAX_SEED_ADDRESSES;
        if (result.stringTruncated) truncations.add("seed-addresses:" + seed.text);
        for (int i = 0; i < Math.min(stringHits.size(), 16); ++i)
            result.stringAddresses.add(hex(stringHits.get(i)));
        nodes.addAll(stringHits);

        Set<Long> frontier = new LinkedHashSet<>(nodes);
        collectReferences(seed, result, frontier, 0, candidates);
        for (int level = 1; level <= 2 && !frontier.isEmpty(); ++level) {
            Set<Long> holders = findPointerHolders(frontier);
            // A __cfstring entry stores its backing-string pointer at
            // struct offset 16, while code normally references the struct
            // base. Add only validated bases so those code references are
            // reachable; retain the field address for data-reference checks.
            Set<Long> expanded = new LinkedHashSet<>(holders);
            for (long holder : holders) {
                long base = normalizeCfStringBase(holder, seed, stringTargets);
                if (base < 0) continue;
                if (result.cfStringBaseOffsets.add(base)) {
                    if (result.cfStringBases.size() < MAX_CFSTRING_BASES_EXPORTED) {
                        result.cfStringBases.add(hex(base));
                    } else {
                        result.cfStringBasesTruncated = true;
                    }
                }
                expanded.add(base);
            }
            holders = expanded;
            holders.removeAll(nodes);
            if (nodes.size() + holders.size() > MAX_TOTAL_NODES) {
                truncations.add("node-budget:" + seed.text);
                break;
            }
            nodes.addAll(holders);
            collectReferences(seed, result, holders, level, candidates);
            frontier = holders;
        }
    }

    // Return a candidate __cfstring base for a pointer field, or -1. Typed
    // Ghidra Data at the exact base is preferred. Otherwise require the full
    // bounded structural shape: aligned nonzero isa word, small flags word,
    // the exact seed pointer at +16 and the exact ASCII seed length at +24.
    // This is a static inference, not proof that a particular runtime object
    // was used as a CFString.
    private long normalizeCfStringBase(long holder, Seed seed, Set<Long> stringTargets) {
        if (stringTargets.isEmpty() || holder < CFSTRING_STRING_POINTER_OFFSET) return -1;
        long base = holder - CFSTRING_STRING_POINTER_OFFSET;
        if ((base & 7L) != 0) return -1;
        Address baseAddress = addr(base);
        Address flagsAddress = addr(base + 8);
        Address stringPointerAddress = addr(holder);
        Address lengthAddress = addr(base + CFSTRING_LENGTH_OFFSET);
        if (baseAddress == null || flagsAddress == null
            || stringPointerAddress == null || lengthAddress == null) return -1;

        Memory memory = currentProgram.getMemory();
        long isa;
        long flags;
        long pointer;
        long length;
        try {
            isa = memory.getLong(baseAddress);
            flags = memory.getLong(flagsAddress);
            pointer = memory.getLong(stringPointerAddress);
            length = memory.getLong(lengthAddress);
        } catch (MemoryAccessException e) {
            return -1;
        }

        long imageBase = currentProgram.getImageBase().getOffset();
        long actualTarget = pointer;
        if (!stringTargets.contains(actualTarget)
            && pointer >= 0 && stringTargets.contains(pointer + imageBase)) {
            actualTarget = pointer + imageBase;
        }
        if (!stringTargets.contains(actualTarget)) return -1;

        int seedBytes = seed.text.getBytes(StandardCharsets.US_ASCII).length;
        if (length < seedBytes) return -1;

        Data data = currentProgram.getListing().getDataContaining(baseAddress);
        boolean typedCfString = false;
        if (data != null && data.getMinAddress() != null
            && data.getMinAddress().getOffset() == base && data.getDataType() != null) {
            String typeName = data.getDataType().getName();
            if (typeName != null) {
                String lowered = typeName.toLowerCase();
                typedCfString = lowered.contains("cfstring")
                    || lowered.contains("constantstring")
                    || lowered.contains("constant_string");
            }
        }
        if (typedCfString) return base;
        if (length != seedBytes) return -1;

        boolean structural = isa != 0 && (isa & 7L) == 0
            && flags >= 0 && flags <= 0x10000L;
        return structural ? base : -1;
    }

    private void collectSymbols(Seed seed, SeedResult result, Set<Long> nodes,
                                Map<Long, Candidate> candidates) {
        SymbolIterator symbols = currentProgram.getSymbolTable().getAllSymbols(true);
        while (symbols.hasNext()) {
            Symbol symbol = symbols.next();
            String name = symbol.getName();
            if (name == null) continue;
            boolean match = seed.substringSymbolMatch
                ? name.contains(seed.text) : name.equals(seed.text);
            if (!match) continue;
            Address address = symbol.getAddress();
            if (address == null) continue;
            long offset = address.getOffset();
            Function function = currentProgram.getFunctionManager().getFunctionAt(address);
            boolean hasBody = function != null && !function.isExternal();
            if (result.symbolHits.size() < 16)
                result.symbolHits.add(new String[]{name, hex(offset), Boolean.toString(hasBody)});
            nodes.add(offset);
            if (hasBody) {
                Candidate candidate = candidateFor(candidates, function);
                credit(candidate, result, seed, name + "@symbol");
            }
        }
    }

    private void collectReferences(Seed seed, SeedResult result, Set<Long> targets,
                                   int level, Map<Long, Candidate> candidates) {
        for (long target : targets) {
            Address address = addr(target);
            if (address == null) continue;
            for (Reference reference : currentProgram.getReferenceManager().getReferencesTo(address)) {
                Function function = currentProgram.getFunctionManager()
                    .getFunctionContaining(reference.getFromAddress());
                if (function == null || function.isExternal()) continue;
                Candidate candidate = candidateFor(candidates, function);
                credit(candidate, result, seed,
                    hex(reference.getFromAddress()) + "->" + hex(target) + ":L" + level
                        + ":" + reference.getReferenceType().getName());
            }
        }
    }

    private Candidate candidateFor(Map<Long, Candidate> candidates, Function function) {
        long entry = function.getEntryPoint().getOffset();
        Candidate candidate = candidates.get(entry);
        if (candidate == null) {
            candidate = new Candidate();
            candidate.entry = entry;
            candidate.name = String.valueOf(function.getName(true));
            AddressSetView body = function.getBody();
            candidate.bodyAddresses = body == null ? 0 : body.getNumAddresses();
            candidate.external = function.isExternal();
            candidate.thunk = function.isThunk();
            candidates.put(entry, candidate);
        }
        return candidate;
    }

    private void credit(Candidate candidate, SeedResult result, Seed seed, String evidence) {
        candidate.seeds.add(seed.text);
        candidate.seedWeights.put(seed.text, seed.weight);
        candidate.referenceCount++;
        if (candidate.references.size() < MAX_REFERENCES_PER_CANDIDATE)
            candidate.references.add(seed.text + "@" + evidence);
        result.candidateEntries.add(candidate.entry);
    }

    private void finishCandidate(Candidate candidate) {
        int score = Math.min(candidate.referenceCount, 10);
        for (int weight : candidate.seedWeights.values()) score += weight;
        candidate.score = score;
        String lowered = candidate.name.toLowerCase();
        if (candidate.name.contains("RK") || candidate.name.contains("UIK")
            || lowered.contains("attest")) {
            candidate.decompileExclusion = "reviewed-rk-uik-region";
        }
    }

    private void collectCalls(Candidate candidate) {
        Function function = currentProgram.getFunctionManager().getFunctionAt(addr(candidate.entry));
        if (function == null) return;
        LinkedHashSet<String> calls = new LinkedHashSet<>();
        InstructionIterator instructions = currentProgram.getListing().getInstructions(function.getBody(), true);
        int seen = 0;
        while (instructions.hasNext()) {
            Instruction instruction = instructions.next();
            if (++seen > MAX_INSTRUCTIONS_PER_CANDIDATE) { candidate.callsTruncated = true; break; }
            if (!instruction.getFlowType().isCall()) continue;
            for (Address flow : instruction.getFlows()) {
                Function target = currentProgram.getFunctionManager().getFunctionAt(flow);
                calls.add(target != null ? String.valueOf(target.getName(true)) : hex(flow));
                if (calls.size() >= MAX_CALLS_PER_CANDIDATE) { candidate.callsTruncated = true; break; }
            }
            if (candidate.callsTruncated) break;
        }
        candidate.calls = new ArrayList<>(calls);
    }

    private int decompileSelected(List<Candidate> exported) {
        int done = 0;
        decompileAttempts = 0;
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) {
                decompilerMessage = boundedDiagnostic(decompiler.getLastMessage());
                truncations.add("decompiler-unavailable");
                return 0;
            }
            decompilerOpened = true;
            decompilerMessage = boundedDiagnostic(decompiler.getLastMessage());
            for (Candidate candidate : exported) {
                if (decompileAttempts >= MAX_DECOMPILE_ATTEMPTS) break;
                if (candidate.decompileExclusion != null || candidate.external || candidate.thunk) continue;
                Function function = currentProgram.getFunctionManager().getFunctionAt(addr(candidate.entry));
                if (function == null) continue;
                decompileAttempts++;
                DecompileResults results = decompiler.decompileFunction(function, DECOMPILE_TIMEOUT_SECONDS, monitor);
                if (results == null || results.getDecompiledFunction() == null) {
                    candidate.decompileError = results == null
                        ? boundedDiagnostic(decompiler.getLastMessage())
                        : boundedDiagnostic(results.getErrorMessage());
                    continue;
                }
                String c = results.getDecompiledFunction().getC();
                if (c == null || c.isEmpty()) continue;
                candidate.pseudocodeTruncated = c.length() > MAX_PSEUDOCODE_CHARS;
                candidate.pseudocode = candidate.pseudocodeTruncated
                    ? c.substring(0, MAX_PSEUDOCODE_CHARS) : c;
                done++;
            }
        } finally {
            decompiler.dispose();
        }
        return done;
    }

    private static String boundedDiagnostic(String value) {
        if (value == null) return null;
        return value.length() > MAX_DIAGNOSTIC_CHARS
            ? value.substring(0, MAX_DIAGNOSTIC_CHARS) : value;
    }

    private List<Long> findAsciiString(String seed) {
        byte[] needle = seed.getBytes(StandardCharsets.US_ASCII);
        List<Long> hits = new ArrayList<>();
        Memory memory = currentProgram.getMemory();
        byte[] buffer = new byte[65536 + needle.length];
        for (MemoryBlock block : memory.getBlocks()) {
            if (!block.isInitialized() || block.isExecute()) continue;
            long remaining = block.getSize();
            long cursor = block.getStart().getOffset();
            int carry = 0;
            while (remaining > 0) {
                int want = (int)Math.min(65536, remaining);
                int got;
                try {
                    // buffer[0..carry) already holds the prior trailing
                    // bytes, so the next source read starts at cursor.
                    got = memory.getBytes(addr(cursor), buffer, carry, want);
                } catch (MemoryAccessException e) {
                    break;
                }
                int total = carry + got;
                for (int i = 0; i + needle.length <= total; ++i) {
                    boolean equal = true;
                    for (int j = 0; j < needle.length; ++j)
                        if (buffer[i + j] != needle[j]) { equal = false; break; }
                    if (equal) hits.add(cursor - carry + i);
                    if (hits.size() > MAX_SEED_ADDRESSES * 4) return hits;
                }
                carry = Math.min(needle.length - 1, total);
                System.arraycopy(buffer, total - carry, buffer, 0, carry);
                cursor += got;
                remaining -= got;
                if (got == 0) break;
            }
        }
        return hits;
    }

    private Set<Long> findPointerHolders(Set<Long> targets) {
        Set<Long> holders = new LinkedHashSet<>();
        if (targets.isEmpty()) return holders;
        long imageBase = currentProgram.getImageBase().getOffset();
        Set<Long> wanted = new HashSet<>();
        for (long target : targets) {
            wanted.add(target);
            if (target >= imageBase) wanted.add(target - imageBase);
        }
        Memory memory = currentProgram.getMemory();
        for (MemoryBlock block : memory.getBlocks()) {
            if (!block.isInitialized() || block.isExecute()) continue;
            long start = block.getStart().getOffset();
            long aligned = start + ((8 - (start % 8)) % 8);
            long end = block.getEnd().getOffset();
            for (long at = aligned; at + 7 <= end; at += 8) {
                long value;
                try {
                    value = memory.getLong(addr(at));
                } catch (MemoryAccessException e) {
                    break;
                }
                if (wanted.contains(value)) {
                    holders.add(at);
                    if (holders.size() > MAX_NODES_PER_LEVEL) {
                        truncations.add("pointer-holders");
                        return holders;
                    }
                }
            }
        }
        return holders;
    }

    private Address addr(long offset) {
        try {
            return currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(offset);
        } catch (Exception e) {
            return null;
        }
    }

    private static String hex(long offset) {
        return "0x" + Long.toHexString(offset);
    }

    private static String hex(Address address) {
        return address == null ? "null" : "0x" + address.toString();
    }

    private static void field(StringBuilder json, int indent, String name, String rawValue, boolean comma) {
        for (int i = 0; i < indent; ++i) json.append(' ');
        json.append(q(name)).append(": ").append(rawValue).append(comma ? ",\n" : "\n");
    }

    private static void appendStrings(StringBuilder json, List<String> values) {
        boolean first = true;
        for (String value : values) {
            if (!first) json.append(",");
            first = false;
            json.append(q(value));
        }
    }

    private static String q(String value) {
        if (value == null) return "null";
        StringBuilder out = new StringBuilder();
        out.append('"');
        for (int i = 0; i < value.length(); ++i) {
            char c = value.charAt(i);
            switch (c) {
                case '"': out.append("\\\""); break;
                case '\\': out.append("\\\\"); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                default:
                    if (c < 0x20) out.append(String.format("\\u%04x", (int)c));
                    else out.append(c);
            }
        }
        out.append('"');
        return out.toString();
    }
}
