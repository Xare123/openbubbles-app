"""Synthetic contract tests for the Find My qualification sidecar.

Every report below is invented in code. No Apple, network, device, profile,
or subprocess operations. Fixtures mirror the probe schema
(windows-findmy-probe-v1) without carrying any real account data.
"""

import copy
import hashlib
import hmac
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
_SPEC = importlib.util.spec_from_file_location(
    "findmy_qualification", HERE / "findmy_qualification.py"
)
fq = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(fq)

LAUNCH = "0123456789abcdef0123456789abcdef"
BUILD = "4388109691ce-dirty-0123456789ab"
EXPECTED = "ab" * 32
EXPECTED_CANONICAL = "handle:selected-probe-person@example.test"
EXPECTED_MESSAGE = (
    "windows-findmy-probe-v1/selected-person/v1:" + EXPECTED_CANONICAL
)
EXPECTED_DIGEST = hmac.new(
    LAUNCH.encode("utf-8"),
    EXPECTED_MESSAGE.encode("utf-8"),
    hashlib.sha256,
).hexdigest()
RESULTS = ("qualified-complete", "partial", "failed", "not-tested")
_UNSET = object()
def _buckets(**overrides):
    buckets = {
        "absent": 0,
        "unknown": 0,
        "future": 0,
        "within_5_minutes": 1,
        "older": 0,
    }
    buckets.update(overrides)
    return buckets


def _lane(
    state="observed",
    fresh=True,
    returned=1,
    present=1,
    valid=1,
    old=0,
    buckets=None,
    extra=None,
    category=None,
    status=None,
    reason=None,
):
    section = {
        "state": state,
        "fresh_request_completed": fresh,
        "returned_count": returned,
    }
    if state == "observed":
        section.update(
            {
                "native_location_present_count": present,
                "valid_coordinate_pair_count": valid,
                "native_is_old_true_count": old,
                "location_age_buckets": (
                    buckets if buckets is not None else _buckets()
                ),
            }
        )
        section.update(extra or {})
    if category is not None:
        section["failure_category"] = category
    if status is not None:
        section["http_status"] = status
    if reason is not None:
        section["reason"] = reason
    return section


def _people(**kwargs):
    extra = {
        "native_opted_not_to_share_true_count": 0,
        "native_opted_not_to_share_false_count": 1,
        "native_opted_not_to_share_unknown_count": 0,
        "native_tk_permission_true_count": 0,
        "native_locate_in_progress_count": 0,
    }
    extra.update(kwargs.pop("extra", {}))
    return _lane(extra=extra, **kwargs)


def _devices(**kwargs):
    return _lane(**kwargs)


def _selection(
    state="observed", requested=True, matched=True, found=True, reason=None,
    buckets=None, valid=1, old=0, digest=_UNSET
):
    section = {
        "state": state,
        "fresh_request_completed": state == "observed",
        "returned_count": 1 if state == "observed" else None,
        "requested": requested,
        "selected_match": matched,
        "location_found": found,
    }
    if digest is not _UNSET:
        section["selected_identity_digest"] = digest
    if reason is not None:
        section["reason"] = reason
    if state == "observed":
        present = 1 if found else 0
        section.update(
            {
                "native_location_present_count": present,
                "valid_coordinate_pair_count": valid if found else 0,
                "native_is_old_true_count": old,
                "location_age_buckets": (
                    buckets if buckets is not None
                    else (_buckets() if found
                          else _buckets(absent=1, within_5_minutes=0))
                ),
            }
        )
    return section


def _items(reason="native_items_initialization_requires_unreviewed_side_effects"):
    section = {
        "state": "not-tested",
        "fresh_request_completed": False,
        "returned_count": None,
    }
    if reason is not None:
        section["reason"] = reason
    return section


def _report(**overrides):
    report = {
        "version": "windows-findmy-probe-v1",
        "launch_id": LAUNCH,
        "build_identifier": BUILD,
        "started_utc": "2026-09-13T00:00:00+00:00",
        "completed_utc": "2026-09-13T00:00:35+00:00",
        "mode": "bounded-findmy-read-only-probe",
        "live_reads_admitted": True,
        "devices": _devices(
            returned=0, present=0, valid=0,
            buckets=_buckets(absent=0, within_5_minutes=0)),
        "people": _people(),
        "selected": _selection(),
        "items": _items(),
    }
    report.update(overrides)
    return report
def _norm(key):
    return "".join(ch for ch in str(key).lower() if ch.isalnum())


def _walk_keys(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            yield key
            yield from _walk_keys(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from _walk_keys(value)


class QualificationContractTests(unittest.TestCase):
    def test_fresh_people_lane_qualifies(self):
        lane = fq.qualify_lane("people", _people())
        self.assertEqual(lane["code"], "fresh-observed")
        self.assertEqual(lane["verdict"], "qualified")
        self.assertTrue(lane["coordinate_present"])
        self.assertEqual(lane["freshness_buckets"]["within_5_minutes"], 1)

    def test_both_lanes_fresh_is_complete(self):
        report = _report(devices=_devices())
        output = fq.qualify_report(report)
        self.assertEqual(output["result"], "qualified-complete")
        self.assertEqual(output["codes"], ["fresh-observed",
                                           "items-not-invoked",
                                           "selection-matched-with-location"])

    def test_partial_when_devices_empty(self):
        output = fq.qualify_report(_report())
        self.assertEqual(output["result"], "partial")
        self.assertEqual(output["lanes"]["devices"]["code"],
                         "empty-inventory")

    def test_empty_inventory_distinct(self):
        lane = fq.qualify_lane(
            "devices",
            _devices(returned=0, present=0, valid=0,
                     buckets=_buckets(absent=0, within_5_minutes=0)),
        )
        self.assertEqual(lane["code"], "empty-inventory")
        self.assertEqual(lane["verdict"], "not-qualified")

    def test_absent_coordinates_distinct(self):
        lane = fq.qualify_lane(
            "people",
            _people(returned=1, present=0, valid=0,
                    buckets=_buckets(absent=1, within_5_minutes=0)),
        )
        self.assertEqual(lane["code"], "absent-coordinates")
        self.assertFalse(lane["coordinate_present"])

    def test_decode_failure_when_present_but_invalid(self):
        lane = fq.qualify_lane(
            "people",
            _people(returned=2, present=2, valid=0,
                    buckets=_buckets(within_5_minutes=2)),
        )
        self.assertEqual(lane["code"], "decode-failure")

    def test_decode_failure_marker(self):
        lane = fq.qualify_lane(
            "devices",
            _lane(state="failed", fresh=False, returned=None,
                  category="decode"),
        )
        self.assertEqual(lane["code"], "decode-failure")
        self.assertEqual(lane["verdict"], "failed")

    def test_stale_location_distinct(self):
        lane = fq.qualify_lane(
            "people",
            _people(old=1, buckets=_buckets(within_5_minutes=0, older=1)),
        )
        self.assertEqual(lane["code"], "stale-location")

    def test_not_fresh_cache_evidence(self):
        lane = fq.qualify_lane(
            "people",
            _lane(state="not-tested", fresh=False, returned=None,
                  reason="fresh_request_not_proven"),
        )
        self.assertEqual(lane["code"], "not-fresh")
    def test_service_auth_failure_401_and_403(self):
        for status in (401, 403):
            with self.subTest(status=status):
                lane = fq.qualify_lane(
                    "people",
                    _lane(state="failed", fresh=False, returned=None,
                          category="http", status=status),
                )
                self.assertEqual(lane["code"], "service-auth-failure")
                self.assertEqual(lane["http_status"], status)

    def test_other_http_is_not_auth_failure(self):
        lane = fq.qualify_lane(
            "devices",
            _lane(state="failed", fresh=False, returned=None,
                  category="http", status=503),
        )
        self.assertEqual(lane["code"], "service-http-failure")
        self.assertEqual(lane["http_status"], 503)

    def test_timeout_and_transport_distinct(self):
        timeout = fq.qualify_lane(
            "people",
            _lane(state="timeout", fresh=False, returned=None,
                  category="timeout"),
        )
        transport = fq.qualify_lane(
            "people",
            _lane(state="failed", fresh=False, returned=None,
                  category="transport"),
        )
        self.assertEqual(timeout["code"], "timeout")
        self.assertEqual(transport["code"], "transport-failure")

    def test_no_live_session_distinct_from_auth(self):
        lane = fq.qualify_lane(
            "people",
            _lane(state="not-tested", fresh=False, returned=None,
                  reason="safe_authenticated_session_unavailable"),
        )
        self.assertEqual(lane["code"], "no-live-session")
        self.assertEqual(lane["verdict"], "not-tested")

    def test_items_never_invoked(self):
        lane = fq.qualify_items(_items())
        self.assertEqual(lane["code"], "items-not-invoked")
        self.assertEqual(lane["verdict"], "not-tested")

    def test_items_live_claim_flagged(self):
        section = _items(reason=None)
        section["state"] = "observed"
        section["fresh_request_completed"] = True
        lane = fq.qualify_items(section)
        self.assertEqual(lane["code"], "items-live-attempted")
        self.assertEqual(lane["verdict"], "failed")

    def test_selection_binding_with_expected_hash(self):
        output = fq.qualify_report(_report(), EXPECTED)
        selection = output["selection"]
        self.assertTrue(selection["expected_supplied"])
        self.assertFalse(selection["binding_available"])
        self.assertNotIn("binding_sha256", selection)
        self.assertEqual(selection["code"],
                         "selection_binding_unavailable")
        self.assertEqual(selection["verdict"], "not-qualified")
        text = json.dumps(output)
        self.assertNotIn(EXPECTED, text)

    def test_matching_selection_digest_qualifies(self):
        report = _report(selected=_selection(digest=EXPECTED_DIGEST))
        selection = fq.qualify_report(report, EXPECTED_DIGEST)["selection"]
        self.assertTrue(selection["binding_available"])
        self.assertEqual(selection["code"],
                         "selection-matched-with-location")
        self.assertEqual(selection["verdict"], "qualified")
        self.assertNotIn(EXPECTED_DIGEST, json.dumps(selection))

    def test_matching_selection_digest_preserves_stale_verdict(self):
        report = _report(selected=_selection(
            digest=EXPECTED_DIGEST,
            buckets=_buckets(within_5_minutes=0, older=1),
            old=1,
        ))
        selection = fq.qualify_report(report, EXPECTED_DIGEST)["selection"]
        self.assertTrue(selection["binding_available"])
        self.assertEqual(selection["code"],
                         "selection-matched-stale-location")
        self.assertEqual(selection["verdict"], "not-qualified")

    def test_mismatched_selection_digest_fails_closed(self):
        report = _report(selected=_selection(digest=EXPECTED_DIGEST))
        selection = fq.qualify_report(report, "00" * 32)["selection"]
        self.assertFalse(selection["binding_available"])
        self.assertEqual(selection["code"], "selection-unmatched")
        self.assertEqual(selection["verdict"], "not-qualified")

    def test_malformed_selection_digest_is_rejected(self):
        report = _report(selected=_selection(digest="zzz"))
        with self.assertRaisesRegex(fq.QualificationError,
                                    "input_rejected_shape"):
            fq.qualify_report(report, EXPECTED_DIGEST)

    def test_unbound_selection_has_no_binding(self):
        selection = fq.qualify_report(_report())["selection"]
        self.assertFalse(selection["expected_supplied"])
        self.assertFalse(selection["binding_available"])
        self.assertNotIn("binding_sha256", selection)
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(_report(), "not-a-hash")

    def test_expected_hash_failed_selection(self):
        report = _report(selected=_selection(state="failed", matched=False,
                                              found=False))
        selection = fq.qualify_report(report, EXPECTED)["selection"]
        self.assertEqual(selection["code"],
                         "selection_binding_unavailable")
        self.assertEqual(selection["verdict"], "failed")
        self.assertNotIn(EXPECTED, json.dumps(selection))

    def test_expected_hash_not_requested(self):
        report = _report(selected=_selection(state="not-tested",
                                              requested=False, matched=False,
                                              found=False,
                                              reason="selection_not_requested"))
        selection = fq.qualify_report(report, EXPECTED)["selection"]
        self.assertEqual(selection["code"], "selection-not-requested")
        self.assertEqual(selection["verdict"], "not-tested")
    def test_observed_with_no_live_session_rejected(self):
        for lane in ("devices", "people"):
            with self.subTest(lane=lane):
                kwargs = {lane: _lane(), "live_reads_admitted": False}
                with self.assertRaises(fq.QualificationError):
                    fq.qualify_report(_report(**kwargs))
        report = _report(live_reads_admitted=False)
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(report)
        items_report = _report(live_reads_admitted=False,
                               devices=_lane(state="not-tested", fresh=False,
                                             returned=None,
                                             reason="safe_authenticated_session_unavailable"),
                               people=_lane(state="not-tested", fresh=False,
                                            returned=None,
                                            reason="safe_authenticated_session_unavailable"),
                               selected=_selection(state="observed"))
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(items_report)

    def test_no_live_session_never_qualifies(self):
        report = _report(
            live_reads_admitted=False,
            devices=_lane(state="not-tested", fresh=False, returned=None,
                          reason="safe_authenticated_session_unavailable"),
            people=_lane(state="not-tested", fresh=False, returned=None,
                         reason="safe_authenticated_session_unavailable"),
            selected=_selection(state="not-tested", requested=False,
                                matched=False, found=False,
                                reason="selection_not_requested"),
        )
        output = fq.qualify_report(report)
        self.assertIn(output["result"], ("failed", "not-tested"))
        for name in ("people", "devices", "items"):
            self.assertNotEqual(output["lanes"][name]["verdict"],
                                "qualified")
        self.assertNotEqual(output["selection"]["verdict"], "qualified")

    def test_top_level_unknown_key_rejected(self):
        bad = _report()
        bad["debug_note"] = "synthetic-canary"
        with self.assertRaises(fq.QualificationError) as caught:
            fq.qualify_report(bad)
        self.assertNotIn("synthetic-canary", str(caught.exception))

    def test_section_unknown_key_rejected(self):
        bad = _report()
        bad["devices"]["extra"] = 1
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(bad)
        bad = _report()
        bad["selected"]["nickname"] = "synthetic-canary"
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(bad)

    def test_buckets_unknown_key_rejected(self):
        bad = _people()
        bad["location_age_buckets"] = _buckets(synthetic_extra=1)
        with self.assertRaises(fq.QualificationError):
            fq.qualify_lane("people", bad)

    def test_meanings_wrong_type_rejected(self):
        bad = _report(location_meaning={"stale": True})
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(bad)

    def test_selection_matched_no_location_real(self):
        report = _report(selected=_selection(found=False))
        selection = fq.qualify_report(report)["selection"]
        self.assertEqual(selection["code"],
                         "selection-matched-no-location")

    def test_selection_not_requested(self):
        report = _report(
            selected=_selection(state="not-tested", requested=False,
                                matched=False, found=False,
                                reason="selection_not_requested")
        )
        selection = fq.qualify_report(report)["selection"]
        self.assertEqual(selection["code"], "selection-not-requested")

    def test_roster_gating_codes(self):
        for reason, code in (
            ("roster_unavailable", "roster-unavailable"),
            ("unique_selected_match_not_found", "no-unique-match"),
            ("sole_person_requires_exactly_one_row",
             "sole-person-unmatched"),
        ):
            with self.subTest(reason=reason):
                report = _report(
                    selected=_selection(state="not-tested", matched=False,
                                        found=False, reason=reason)
                )
                selection = fq.qualify_report(report)["selection"]
                self.assertEqual(selection["code"], code)

    def test_rejects_wrong_version_and_identity(self):
        bad = _report(version="windows-findmy-probe-v9")
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(bad)
        bad = _report(launch_id="ZZZ")
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(bad)
        bad = _report(mode="live-unbounded")
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(bad)

    def test_rejects_forbidden_fields_without_echo(self):
        bad = _report()
        bad["people"]["latitude"] = 47.6062
        with self.assertRaises(fq.QualificationError) as caught:
            fq.qualify_report(bad)
        self.assertNotIn("47.6062", str(caught.exception))
        bad = _report()
        bad["selectedPersonId"] = "synthetic-raw-id"
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(bad)
        bad = _report()
        bad["people"]["token"] = "synthetic-token"
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(bad)

    def test_unknown_keys_are_dropped_never_echoed(self):
        report = _report()
        report["people"]["nickname"] = "Synthetic Spouse Canary"
        with self.assertRaises(fq.QualificationError) as caught:
            fq.qualify_report(report)
        self.assertNotIn("Synthetic Spouse Canary", str(caught.exception))

    def test_output_contract_safe(self):
        output = fq.qualify_report(_report(), EXPECTED)
        self.assertIn(output["result"], RESULTS)
        for code in output["codes"]:
            self.assertIn(code, fq._SAFE_CODES)
        for key in _walk_keys(output):
            self.assertNotIn(_norm(key), fq._FORBIDDEN)

    def test_failed_both_lanes_is_failed(self):
        report = _report(
            people=_lane(state="failed", fresh=False, returned=None,
                          category="generic"),
            devices=_lane(state="failed", fresh=False, returned=None,
                           category="generic"),
            selected=_selection(state="not-tested", matched=False,
                                  found=False,
                                  reason="roster_unavailable"),
        )
        output = fq.qualify_report(report)
        self.assertEqual(output["result"], "failed")

    def test_module_is_read_only(self):
        for module in ("socket", "subprocess", "urllib.request", "ssl",
                       "http.client"):
            self.assertNotIn(module, sys.modules)
        source = Path(fq.__file__).read_text(encoding="utf-8")
        for line in source.splitlines():
            stripped = line.strip()
            self.assertFalse(stripped.startswith("import socket"), line)
            self.assertFalse(stripped.startswith("import subprocess"), line)
            self.assertFalse(stripped.startswith("import urllib"), line)
            self.assertFalse(stripped.startswith("from socket"), line)
            self.assertFalse(stripped.startswith("from subprocess"), line)
            self.assertFalse(stripped.startswith("from urllib"), line)
        for token in ("Popen(", "os.system(", "selectFriend", "makeFindMy",
                      "refreshDevices", "setupPush", "check_output",
                      "urlopen(", "socket."):
            self.assertNotIn(token, source)

    def test_cli_end_to_end_synthetic(self):
        import tempfile as _tf
        with _tf.TemporaryDirectory(prefix="findmy-qual-synthetic-") as tmp:
            path = Path(tmp) / "report.json"
            path.write_text(json.dumps(_report()), encoding="utf-8")
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                code = fq.main(["--report", str(path),
                                "--expected-person-sha256", EXPECTED])
            self.assertEqual(code, 0)
            output = json.loads(buffer.getvalue())
            self.assertEqual(output["launch_id"], LAUNCH)
            self.assertEqual(output["result"], "partial")

    def test_cli_bad_hash_exits_unclean_without_echo(self):
        import tempfile as _tf2
        with _tf2.TemporaryDirectory(prefix="findmy-qual-synthetic-") as tmp:
            path = Path(tmp) / "report.json"
            path.write_text(json.dumps(_report()), encoding="utf-8")
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                code = fq.main(["--report", str(path),
                                "--expected-person-sha256", "zzz"])
            self.assertEqual(code, 2)

    def test_rejects_bucket_sum_mismatch(self):
        bad = _people(buckets=_buckets(within_5_minutes=2))
        with self.assertRaises(fq.QualificationError):
            fq.qualify_lane("people", bad)

    def test_rejects_observed_without_count(self):
        section = _people()
        section["returned_count"] = None
        with self.assertRaises(fq.QualificationError):
            fq.qualify_lane("people", section)

    def test_rejects_impossible_counts(self):
        bad = _people(present=1, valid=2)
        with self.assertRaises(fq.QualificationError):
            fq.qualify_lane("people", bad)

    def test_unknown_timestamp_only_is_stale(self):
        lane = fq.qualify_lane(
            "people",
            _people(buckets=_buckets(unknown=1, within_5_minutes=0)),
        )
        self.assertEqual(lane["code"], "stale-location")
        self.assertEqual(lane["verdict"], "not-qualified")

    def test_selection_stale_location_distinct(self):
        report = _report(selected=_selection(
            buckets=_buckets(within_5_minutes=0, older=1), old=1))
        selection = fq.qualify_report(report)["selection"]
        self.assertEqual(selection["code"],
                         "selection-matched-stale-location")
        self.assertEqual(selection["verdict"], "not-qualified")

    def test_selection_found_without_present_is_rejected(self):
        section = _selection()
        section["native_location_present_count"] = 0
        report = _report(selected=section)
        with self.assertRaises(fq.QualificationError):
            fq.qualify_report(report)

    def test_selection_invalid_pair_is_no_location(self):
        report = _report(selected=_selection(valid=0))
        selection = fq.qualify_report(report)["selection"]
        self.assertEqual(selection["code"],
                         "selection-matched-no-location")

    def test_selection_observed_requires_aggregates(self):
        section = _selection()
        for key in ("native_location_present_count",
                    "valid_coordinate_pair_count",
                    "native_is_old_true_count", "location_age_buckets"):
            pruned = _selection()
            del pruned[key]
            with self.subTest(key=key):
                with self.assertRaises(fq.QualificationError):
                    fq.qualify_report(_report(selected=pruned))


if __name__ == "__main__":
    unittest.main()
