"""Allowlisted observations from a private validator; raw error text is never logged."""
import json
import math
import re

EXPECTED_STEPS = ["framework", "hardware", "bag", "certificate", "nac_init",
                  "session", "key_establishment", "sign", "complete"]
FIELDS = {
    "framework":{"sha256","bytes","hash_verified"},
    "hardware":{"input_bytes","input_sha256","encrypted_fields","identity_preserved"},
    "bag":{"http_status","bytes"},
    "certificate":{"http_status","bytes"},
    "nac_init":{"request_bytes","result"},
    "session":{"http_status","bytes"},
    "key_establishment":{"response_bytes","result"},
    "sign":{"proof_bytes","proof_sha256","result","account_acceptance","production_integration"},
    "complete":{"elapsed_seconds"},
    "failed":{"error","phase","elapsed_seconds"},
}
COUNTERS = {"bytes","input_bytes","http_status","request_bytes","response_bytes","proof_bytes"}
HASHES = {"sha256","input_sha256","proof_sha256"}
BOOLEANS = {"hash_verified","identity_preserved"}
FAILURE_PHASES = {"startup","framework","engine","input","hardware","client",
                  "bag_request","bag_decode","bag_urls","certificate_request",
                  "certificate_decode","nac_init","session_encode","session_request",
                  "session_decode","key_establishment","sign"}
EMULATION_FAULTS = {"READ_UNMAPPED", "WRITE_UNMAPPED", "FETCH_UNMAPPED",
                    "READ_PROT", "WRITE_PROT", "FETCH_PROT", "INSN_INVALID",
                    "EXCEPTION", "ARG", "NOMEM", "RESOURCE"}
NATIVE_ERROR_PREFIXES = {
    "NAC emulation stopped before return: timeout": "emulation_timeout",
    "NAC emulation stopped before return: instruction_limit_or_hook": "emulation_instruction_limit_or_hook",
    "NAC emulation stopped before return: unknown_timeout_state": "emulation_stop_unclassified",
    "NAC hook failure index invalid": "emulation_hook_failure",
    "Unicorn init failed:": "engine_initialization",
    "Failed to map ": "emulator_memory_mapping",
    "Mach-O parse error:": "framework_parse",
    "Mach-O imports parse failure:": "framework_import_parse",
    "Failed to write import:": "framework_import_write",
    "NAC emulation stopped before return": "emulation_incomplete",
    "NAC stop did not consume": "emulation_invalid_return",
    "NACInit output bounds invalid": "nac_init_output_bounds",
    "NAC image overlaps reserved memory": "framework_layout",
    "NAC import slot outside image": "framework_import_bounds",
    "NAC import table exceeds bound": "framework_import_bounds",
}


def sanitize_output(raw, require_complete=False):
    if len(raw) > 128 * 1024:
        raise ValueError("private diagnostic output exceeds bound")
    safe = []
    try:
        events = [json.loads(line) for line in raw.decode("utf-8").splitlines() if line.strip()]
    except (ValueError, UnicodeError):
        raise ValueError("private diagnostic is not bounded JSON metadata") from None
    if len(events) > 16:
        raise ValueError("too many private diagnostic events")
    for event in events:
        if not isinstance(event, dict):
            raise ValueError("private diagnostic event must be an object")
        step = event.get("step")
        if step not in FIELDS or set(event) - (FIELDS[step] | {"step"}):
            raise ValueError("unapproved private diagnostic fields")
        row = {"step":step}
        for key, value in event.items():
            if key == "step":
                continue
            if key == "error":
                # Native/plist/network errors may contain remote values.
                row["error_kind"] = "validation_failed"
                if isinstance(value, str):
                    code = re.fullmatch(r"NAC return code (-?[0-9]{1,10})", value)
                    status = re.fullmatch(r"(bag|certificate|session) HTTP ([0-9]{3})", value)
                    hook = re.fullmatch(r"NAC hook panic ([0-9]{1,2})", value)
                    if code:
                        row.update(error_kind="nac_return_code", error_code=int(code[1]))
                    elif status:
                        row.update(error_kind="apple_http_status", http_status=int(status[2]))
                    elif hook and int(hook[1]) < 37:
                        row.update(error_kind="emulation_hook_failure", hook_index=int(hook[1]))
                    else:
                        fault = re.fullmatch(r"Emulation error at 0x[0-9a-f]{1,16}: ([A-Z_]+)", value)
                        if fault and fault[1] in EMULATION_FAULTS:
                            row.update(error_kind="emulation_fault", emulation_fault=fault[1])
                        else:
                            for prefix, category in NATIVE_ERROR_PREFIXES.items():
                                if value.startswith(prefix):
                                    row["error_kind"] = category
                                    break
                continue
            if key == "phase":
                valid = isinstance(value, str) and value in FAILURE_PHASES
            elif key in COUNTERS:
                valid = type(value) is int and 0 <= value <= 1000000000
            elif key in HASHES:
                valid = isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
            elif key in BOOLEANS:
                valid = type(value) is bool
            elif key == "encrypted_fields":
                valid = isinstance(value, list) and len(value) == 5 and all(type(x) is int and 1 <= x <= 256 for x in value)
            elif key == "elapsed_seconds":
                valid = type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 600
            elif key == "result":
                valid = value == ("generated" if step == "sign" else "success")
            else:
                valid = value == "UNRUN"
            if not valid:
                raise ValueError("unapproved private diagnostic value")
            row[key] = value
        safe.append(row)
    if require_complete:
        if [row["step"] for row in safe] != EXPECTED_STEPS:
            raise ValueError("incomplete private validation observations")
        for event in events:
            if set(event) != FIELDS[event["step"]] | {"step"}:
                raise ValueError("required private observation missing")
        if (not safe[0]["hash_verified"] or not safe[1]["identity_preserved"] or
                any(safe[i]["http_status"] != 200 for i in (2, 3, 5)) or
                safe[7]["proof_bytes"] < 1):
            raise ValueError("validation did not prove the required exchange")
    return ("\n".join(json.dumps(event, sort_keys=True) for event in safe) + "\n").encode("utf-8")
