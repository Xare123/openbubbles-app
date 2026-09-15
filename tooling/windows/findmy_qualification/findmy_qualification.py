"""Bounded Windows Find My qualification tester (offline sidecar).

Reads a saved report from the existing read-only Windows probe
(lib/cloud_sync_v2_windows_findmy_probe.dart, schema
windows-findmy-probe-v1) and emits per-lane qualification verdicts for
People, Devices, and Items. When the probe supplies its per-launch redacted
selected-identity digest, --expected-person-sha256 binds the selected row to
the operator's independently computed expectation. Missing or mismatched
binding evidence fails closed.

Read-only by construction: standard library only, no network access, no
subprocess use, no profile access. It never changes sharing, never rings an
item, and has no flags that enable live behavior.
"""

import argparse
import json
import re
import sys

PROBE_VERSION = "windows-findmy-probe-v1"
QUALIFIER_VERSION = "windows-findmy-qualification-v1"
PROBE_MODE = "bounded-findmy-read-only-probe"
TESTHOST_VERSION = "findmy-windows-testhost-v1"
TESTHOST_MODE = "service-reads-with-authorized-local-and-auth-housekeeping"

_LAUNCH_RE = re.compile(r"^[a-f0-9]{32}$")
_BUILD_RE = re.compile(r"^[a-f0-9]{7,40}(?:-dirty-[a-f0-9]{12})?$")
_HEX64_RE = re.compile(r"^[a-f0-9]{64}$")
_MAX_REPORT_BYTES = 256 * 1024

_BUCKET_KEYS = ("absent", "unknown", "future", "within_5_minutes", "older")
_DEVICE_CLASSES = frozenset(
    {"iphone", "ipad", "mac", "watch", "airpods", "ipod", "accessory", "other"}
)
_FORBIDDEN = frozenset(
    {
        "address", "coord", "coordinate", "coordinates",
        "credential", "credentials", "displayname", "dsid",
        "email", "firstname", "fullname", "handle", "handles",
        "history", "home", "id", "identity", "lastname",
        "lat", "latitude", "lng", "lon", "location", "locations",
        "longitude", "name", "names", "password", "passwords",
        "personid", "deviceid", "rawid", "secret", "secrets",
        "selectedhandle", "selectedpersonid", "token", "tokens",
        "userid",
    }
)

_SAFE_CODES = frozenset(
    {
        "fresh-observed", "empty-inventory", "absent-coordinates",
        "decode-failure", "stale-location", "not-fresh",
        "service-auth-failure", "service-http-failure",
        "transport-failure", "read-failed-generic", "timeout",
        "no-live-session", "not-tested", "selection-not-requested",
        "selection-matched-with-location", "selection-matched-no-location",
        "selection-unmatched", "roster-unavailable", "no-unique-match",
        "sole-person-unmatched", "selection-matched-stale-location",
        "selection_binding_unavailable", "items-not-invoked",
        "items-live-attempted",
    }
)

_STATES = ("observed", "failed", "timeout", "not-tested")
_CATEGORIES = ("timeout", "decode", "transport", "http", "generic")
_RESULTS = ("qualified-complete", "partial", "failed", "not-tested")

_PEOPLE_COUNTS = (
    "native_opted_not_to_share_true_count",
    "native_opted_not_to_share_false_count",
    "native_opted_not_to_share_unknown_count",
    "native_tk_permission_true_count",
    "native_locate_in_progress_count",
)
_DEVICE_COUNTS = ("native_family_share_true_count",)
_SOLE_PERSON_REASONS = frozenset(
    {
        "sole_person_fresh_roster_unavailable",
        "sole_person_requires_exactly_one_row",
        "sole_person_id_invalid",
    }
)
_TOP_KEYS = frozenset(
    {
        "version", "launch_id", "build_identifier", "started_utc",
        "completed_utc", "mode", "live_reads_admitted",
        "location_meaning", "sharing_meaning", "freshness_meaning",
        "devices", "people", "selected", "items",
    }
)
_TESTHOST_KEYS = frozenset(
    {
        "version", "launch_id", "process_id", "native_sha256", "mode",
        "abi_verified", "select_sole_person", "state", "stage", "probe",
    }
)
_MEANING_KEYS = ("location_meaning", "sharing_meaning", "freshness_meaning")
_COMMON_LANE_KEYS = frozenset(
    {
        "state", "fresh_request_completed", "returned_count", "reason",
        "failure_category", "http_status",
        "native_location_present_count", "valid_coordinate_pair_count",
        "native_is_old_true_count", "location_age_buckets",
    }
)
_PEOPLE_KEYS = _COMMON_LANE_KEYS | frozenset(_PEOPLE_COUNTS)
_DEVICE_KEYS = _COMMON_LANE_KEYS | frozenset(_DEVICE_COUNTS) | frozenset(["classes"])
_SELECTED_KEYS = _COMMON_LANE_KEYS | frozenset(
    ["requested", "selected_match", "location_found", "selected_identity_digest"]
) | frozenset(_PEOPLE_COUNTS)
_ITEMS_KEYS = frozenset(["state", "fresh_request_completed", "returned_count", "reason"])
class QualificationError(Exception):
    pass


def _norm(key):
    return re.sub(r"[^a-z0-9]", "", str(key).lower())


def _scan_forbidden(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if _norm(key) in _FORBIDDEN:
                raise QualificationError("input_rejected_forbidden_field")
            _scan_forbidden(value)
    elif isinstance(obj, list):
        for value in obj:
            _scan_forbidden(value)


def _check_keys(section, allowed):
    if not isinstance(section, dict):
        raise QualificationError("input_rejected_shape")
    for key in section:
        if key not in allowed:
            raise QualificationError("input_rejected_unknown_key")


def _extract_probe_report(report):
    """Accept the probe itself or the exact successful live-testhost envelope."""
    if not isinstance(report, dict):
        raise QualificationError("input_rejected_shape")
    if report.get("version") != TESTHOST_VERSION:
        return report

    _check_keys(report, _TESTHOST_KEYS)
    _scan_forbidden(report)
    launch_id = report.get("launch_id")
    process_id = report.get("process_id")
    native_sha256 = report.get("native_sha256")
    if not isinstance(launch_id, str) or not _LAUNCH_RE.match(launch_id):
        raise QualificationError("input_rejected_identity")
    if (isinstance(process_id, bool) or not isinstance(process_id, int)
            or process_id <= 0):
        raise QualificationError("input_rejected_shape")
    if not isinstance(native_sha256, str) or not _HEX64_RE.match(native_sha256):
        raise QualificationError("input_rejected_shape")
    if report.get("mode") != TESTHOST_MODE:
        raise QualificationError("input_rejected_shape")
    if report.get("abi_verified") is not True:
        raise QualificationError("input_rejected_shape")
    if not isinstance(report.get("select_sole_person"), bool):
        raise QualificationError("input_rejected_shape")
    if report.get("state") != "finished":
        raise QualificationError("input_rejected_shape")
    if report.get("stage") not in (
            "findmy-probe-complete", "findmy-probe-partial"):
        raise QualificationError("input_rejected_shape")
    probe = report.get("probe")
    if not isinstance(probe, dict) or probe.get("launch_id") != launch_id:
        raise QualificationError("input_rejected_identity")
    return probe


def _req_bool(section, key):
    value = section.get(key)
    if not isinstance(value, bool):
        raise QualificationError("input_rejected_shape")
    return value


def _req_count(section, key):
    value = section.get(key)
    if not isinstance(value, int) or value < 0:
        raise QualificationError("input_rejected_shape")
    return value


def _buckets(section):
    raw = section.get("location_age_buckets")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise QualificationError("input_rejected_shape")
    _check_keys(raw, _BUCKET_KEYS)
    out = {}
    for key in _BUCKET_KEYS:
        value = raw.get(key)
        if not isinstance(value, int) or value < 0:
            raise QualificationError("input_rejected_shape")
        out[key] = value
    return out


def _req_buckets(section):
    buckets = _buckets(section)
    if buckets is None:
        raise QualificationError("input_rejected_shape")
    return buckets
def _copy_counts(section, keys):
    out = {}
    for key in keys:
        if key in section:
            out[key] = _req_count(section, key)
    return out


def _copy_classes(section):
    raw = section.get("classes")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise QualificationError("input_rejected_shape")
    out = {}
    for key, value in raw.items():
        if key not in _DEVICE_CLASSES:
            raise QualificationError("input_rejected_shape")
        if not isinstance(value, int) or value < 0:
            raise QualificationError("input_rejected_shape")
        out[key] = value
    return out


def _failure_details(section, out):
    category = section.get("failure_category")
    status = section.get("http_status")
    if category is not None:
        if category not in _CATEGORIES:
            raise QualificationError("input_rejected_shape")
        out["failure_category"] = category
    if status is not None:
        if not isinstance(status, int) or status < 100 or status > 599:
            raise QualificationError("input_rejected_shape")
        out["http_status"] = status
    return category, status


def _nontested_code(reason):
    if reason is None:
        return "not-tested"
    if not isinstance(reason, str):
        raise QualificationError("input_rejected_shape")
    if reason == "safe_authenticated_session_unavailable":
        return "no-live-session"
    if reason == "fresh_request_not_proven":
        return "not-fresh"
    if reason == "roster_unavailable":
        return "roster-unavailable"
    if reason == "unique_selected_match_not_found":
        return "no-unique-match"
    if reason in _SOLE_PERSON_REASONS:
        return "sole-person-unmatched"
    return "not-tested"
def qualify_lane(lane, section):
    if not isinstance(section, dict):
        raise QualificationError("input_rejected_shape")
    if lane == "devices":
        _check_keys(section, _DEVICE_KEYS)
    elif lane == "people":
        _check_keys(section, _PEOPLE_KEYS)
    else:
        raise QualificationError("input_rejected_shape")
    state = section.get("state")
    if state not in _STATES:
        raise QualificationError("input_rejected_shape")
    fresh = _req_bool(section, "fresh_request_completed")
    returned = section.get("returned_count")
    if returned is not None and (not isinstance(returned, int) or returned < 0):
        raise QualificationError("input_rejected_shape")
    out = {
        "lane": lane,
        "state": state,
        "fresh_request_completed": fresh,
        "returned_count": returned,
        "coordinate_present": None,
        "valid_pair_present": None,
        "freshness_buckets": None,
    }
    if lane == "devices":
        out.update(_copy_counts(section, _DEVICE_COUNTS))
        classes = _copy_classes(section)
        if classes is not None:
            out["classes"] = classes
    elif lane == "people":
        out.update(_copy_counts(section, _PEOPLE_COUNTS))
    if state == "observed":
        if not fresh:
            out.update(code="not-fresh", verdict="not-qualified")
            return out
        present = _req_count(section, "native_location_present_count")
        valid = _req_count(section, "valid_coordinate_pair_count")
        old = _req_count(section, "native_is_old_true_count")
        buckets = _req_buckets(section)
        if not isinstance(returned, int) or returned < 0:
            raise QualificationError("input_rejected_shape")
        if sum(buckets.values()) != returned:
            raise QualificationError("input_rejected_shape")
        if present > returned or valid > present or old > present:
            raise QualificationError("input_rejected_shape")
        out.update(
            coordinate_present=present > 0,
            valid_pair_present=valid > 0,
            freshness_buckets=buckets,
        )
        if returned == 0:
            out.update(code="empty-inventory", verdict="not-qualified")
        elif present <= 0:
            out.update(code="absent-coordinates", verdict="not-qualified")
        elif valid <= 0:
            out.update(code="decode-failure", verdict="not-qualified")
        elif buckets["within_5_minutes"] <= 0:
            out.update(code="stale-location", verdict="not-qualified")
        else:
            out.update(code="fresh-observed", verdict="qualified")
        return out
    if state == "timeout":
        category, _status = _failure_details(section, out)
        if category is not None and category != "timeout":
            raise QualificationError("input_rejected_shape")
        out.update(code="timeout", verdict="failed")
        return out
    if state == "failed":
        category, status = _failure_details(section, out)
        if category == "decode":
            code = "decode-failure"
        elif category == "http" and status in (401, 403):
            code = "service-auth-failure"
        elif category == "http":
            code = "service-http-failure"
        elif category == "transport":
            code = "transport-failure"
        else:
            code = "read-failed-generic"
        out.update(code=code, verdict="failed")
        return out
    code = _nontested_code(section.get("reason"))
    _failure_details(section, out)
    out.update(code=code, verdict="not-tested")
    return out
def qualify_items(section):
    if not isinstance(section, dict):
        raise QualificationError("input_rejected_shape")
    _check_keys(section, _ITEMS_KEYS)
    state = section.get("state")
    if state not in _STATES:
        raise QualificationError("input_rejected_shape")
    fresh = _req_bool(section, "fresh_request_completed")
    returned = section.get("returned_count")
    if returned is not None:
        raise QualificationError("input_rejected_shape")
    out = {
        "lane": "items",
        "state": state,
        "fresh_request_completed": fresh,
        "returned_count": None,
        "coordinate_present": None,
        "valid_pair_present": None,
        "freshness_buckets": None,
    }
    if state == "not-tested":
        out.update(code="items-not-invoked", verdict="not-tested")
    else:
        out.update(code="items-live-attempted", verdict="failed")
    return out


def _check_selection_aggregates(section, matched, found):
    present = _req_count(section, "native_location_present_count")
    valid = _req_count(section, "valid_coordinate_pair_count")
    _req_count(section, "native_is_old_true_count")
    buckets = _req_buckets(section)
    if sum(buckets.values()) != (1 if matched else 0):
        raise QualificationError("input_rejected_shape")
    if present > 1 or valid > present:
        raise QualificationError("input_rejected_shape")
    if found != (present > 0):
        raise QualificationError("input_rejected_shape")
    return present, valid, buckets


def qualify_selection(section, launch_id, expected_hash=None):
    if not isinstance(section, dict):
        raise QualificationError("input_rejected_shape")
    _check_keys(section, _SELECTED_KEYS)
    state = section.get("state")
    if state not in _STATES:
        raise QualificationError("input_rejected_shape")
    _req_bool(section, "fresh_request_completed")
    requested = _req_bool(section, "requested")
    matched = section.get("selected_match")
    found = section.get("location_found")
    if not isinstance(matched, bool) or not isinstance(found, bool):
        raise QualificationError("input_rejected_shape")
    digest = section.get("selected_identity_digest")
    if digest is not None:
        if not isinstance(digest, str) or not _HEX64_RE.match(digest):
            raise QualificationError("input_rejected_shape")
        if not requested or state != "observed" or not matched:
            raise QualificationError("input_rejected_shape")
    out = {
        "requested": requested,
        "matched": matched,
        "location_found": found,
        "coordinate_present": found,
        "expected_supplied": expected_hash is not None,
        "binding_available": False,
    }
    if not requested:
        out.update(state=state, code="selection-not-requested", verdict="not-tested")
        return out
    if expected_hash is not None:
        if state == "observed":
            _check_selection_aggregates(section, matched, found)
        if digest is None:
            if state in ("failed", "timeout"):
                out.update(state=state, code="selection_binding_unavailable",
                           verdict="failed")
            else:
                out.update(state=state, code="selection_binding_unavailable",
                           verdict="not-qualified")
            return out
        if digest != expected_hash:
            out.update(state=state, code="selection-unmatched",
                       verdict="not-qualified")
            return out
        out["binding_available"] = True
    if state == "observed":
        present, valid, buckets = _check_selection_aggregates(section, matched,
                                                              found)
        if matched and found:
            if valid <= 0:
                out.update(state=state,
                           code="selection-matched-no-location",
                           verdict="not-qualified")
            elif buckets["within_5_minutes"] <= 0:
                out.update(state=state,
                           code="selection-matched-stale-location",
                           verdict="not-qualified")
            else:
                out.update(state=state,
                           code="selection-matched-with-location",
                           verdict="qualified")
        elif matched:
            out.update(state=state, code="selection-matched-no-location",
                       verdict="not-qualified")
        else:
            out.update(state=state, code="selection-unmatched",
                       verdict="not-qualified")
        return out
    if state in ("failed", "timeout"):
        out.update(state=state, code="read-failed-generic", verdict="failed")
        return out
    reason = section.get("reason")
    if reason == "roster_unavailable":
        code = "roster-unavailable"
    elif reason == "unique_selected_match_not_found":
        code = "no-unique-match"
    elif reason in _SOLE_PERSON_REASONS:
        code = "sole-person-unmatched"
    elif reason == "selection_not_requested":
        code = "selection-not-requested"
    else:
        code = "not-tested"
    out.update(state=state, code=code, verdict="not-tested")
    return out


def qualify_report(report, expected_hash=None):
    report = _extract_probe_report(report)
    _check_keys(report, _TOP_KEYS)
    _scan_forbidden(report)
    if report.get("version") != PROBE_VERSION:
        raise QualificationError("input_rejected_version")
    launch_id = report.get("launch_id")
    build_id = report.get("build_identifier")
    if not isinstance(launch_id, str) or not _LAUNCH_RE.match(launch_id):
        raise QualificationError("input_rejected_identity")
    if not isinstance(build_id, str) or not _BUILD_RE.match(build_id):
        raise QualificationError("input_rejected_identity")
    live = report.get("live_reads_admitted")
    if not isinstance(live, bool):
        raise QualificationError("input_rejected_shape")
    mode = report.get("mode")
    if mode is not None and mode != PROBE_MODE:
        raise QualificationError("input_rejected_shape")
    for key in ("started_utc", "completed_utc"):
        if key in report and not isinstance(report[key], str):
            raise QualificationError("input_rejected_shape")
    for key in _MEANING_KEYS:
        if key in report and not isinstance(report[key], str):
            raise QualificationError("input_rejected_shape")
    for lane in ("devices", "people", "selected", "items"):
        if lane not in report:
            raise QualificationError("input_rejected_shape")
    if expected_hash is not None and not _HEX64_RE.match(expected_hash):
        raise QualificationError("input_rejected_bad_expected_hash")
    if not live:
        for lane in ("devices", "people", "selected", "items"):
            section = report[lane]
            if isinstance(section, dict) and section.get("state") == "observed":
                raise QualificationError("input_rejected_shape")
    people = qualify_lane("people", report["people"])
    devices = qualify_lane("devices", report["devices"])
    items = qualify_items(report["items"])
    selection = qualify_selection(report["selected"], launch_id, expected_hash)
    if people["verdict"] == "qualified" and devices["verdict"] == "qualified":
        result = "qualified-complete"
    elif (people["verdict"] == "qualified"
            or devices["verdict"] == "qualified"
            or people["state"] == "observed"
            or devices["state"] == "observed"):
        result = "partial"
    elif people["verdict"] == "failed" and devices["verdict"] == "failed":
        result = "failed"
    else:
        result = "not-tested"
    if not live and result in ("qualified-complete", "partial"):
        result = "not-tested"
    codes = sorted({people["code"], devices["code"], items["code"],
                    selection["code"]})
    for code in codes:
        if code not in _SAFE_CODES:
            raise QualificationError("internal_code_not_allowlisted")
    output = {
        "version": QUALIFIER_VERSION,
        "probe_version": PROBE_VERSION,
        "launch_id": launch_id,
        "build_identifier": build_id,
        "live_reads_admitted": live,
        "result": result,
        "codes": codes,
        "lanes": {"people": people, "devices": devices, "items": items},
        "selection": selection,
    }
    _scan_forbidden(output)
    return output


def _parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="findmy_qualification.py",
        description="Offline qualifier for a saved Windows Find My probe report.",
    )
    parser.add_argument("--report", required=True, help="Saved probe JSON file")
    parser.add_argument("--expected-person-sha256", default=None,
                        help="64-hex per-launch identity digest computed "
                        "independently; missing or mismatched probe evidence "
                        "fails closed")
    parser.add_argument("--out", default=None, help="Output file (else stdout)")
    return parser.parse_args(argv)


def main(argv=None):
    try:
        args = _parse_args(argv)
        expected = args.expected_person_sha256
        if expected is not None:
            expected = expected.strip().lower()
        with open(args.report, "rb") as stream:
            raw = stream.read(_MAX_REPORT_BYTES + 1)
        if len(raw) > _MAX_REPORT_BYTES:
            raise QualificationError("input_rejected_too_large")
        try:
            report = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise QualificationError("input_rejected_unparseable")
        output = qualify_report(report, expected)
        encoded = json.dumps(output, indent=2, sort_keys=True)
        if args.out is None:
            sys.stdout.write(encoded + "\n")
        else:
            with open(args.out, "w", encoding="utf-8") as stream:
                stream.write(encoded + "\n")
        return 0
    except QualificationError as error:
        sys.stderr.write("findmy_qualification_rejected: {}\n".format(error))
        return 2
    except OSError:
        sys.stderr.write("findmy_qualification_rejected: input_unreadable\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
