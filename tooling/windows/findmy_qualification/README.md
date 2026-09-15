# Windows Find My qualification tester (offline sidecar)

Bounded offline qualifier for the existing read-only Windows Find My probe.
It performs no live reads, opens no network connections, touches no profile,
and changes nothing. Live reads stay exactly where they are today.

## Reuse map (nothing duplicated here)

Read-only People and Device refresh plus selection:
    lib/cloud_sync_v2_windows_findmy_probe.dart
Artifact, mutex, process guard, live launch:
    tooling/windows/run_findmy_windows_live.ps1
Retained-profile safety checks:
    tooling/windows/findmy_windows_preflight.py
Bounded live test host:
    test/live/findmy_windows_live_test.dart
Offline verdicts over a saved probe report: this folder (new).

The qualifier consumes a saved probe-report JSON object (schema
windows-findmy-probe-v1, as in report.json from the launcher flow) and emits
per-lane verdicts for People, Devices, and Items plus a hashed selection
binding. Items are never invoked: the probe reports them not-tested by
design, and this tester keeps that guard.

## Usage (PowerShell 7, from the repo root)

Qualify a saved report (read-only, prints to stdout):

    python tooling/windows/findmy_qualification/findmy_qualification.py --report <path-to-report.json>

Bind an operator expectation without exposing the person (digest computed
elsewhere, never echoed back):

    python tooling/windows/findmy_qualification/findmy_qualification.py --report <path-to-report.json> --expected-person-sha256 <64-hex>

The flag fails closed by design. It compares the independently computed
per-launch digest with selected_identity_digest from the probe. A missing
digest produces selection_binding_unavailable; a mismatch produces
selection-unmatched. The qualifier never echoes either digest. The value is
an equality binding for controlled evidence, not secret authentication,
because launch_id is present in the same report.

Use --out <path> to write to a file instead of stdout. There are no flags
for sharing changes, ringing, live reads, writes, or destructive actions;
unknown flags are rejected.

## Input contract

Top-level report dict, version exactly windows-findmy-probe-v1. launch_id is
32 lowercase hex; build_identifier follows the probe contract pattern. Each
of devices, people, selected, items carries state in
observed/failed/timeout/not-tested, a fresh_request_completed bool, and a
returned_count int or null.
Top-level keys, per-section keys, and bucket keys must match the pinned
probe schema exactly; anything unknown fails closed with
input_rejected_unknown_key, so future sensitive extensions cannot slip past
name screening. If live_reads_admitted is false, any state=observed is
rejected outright and no lane may report a qualified verdict.

Any forbidden field (names, coordinates, raw IDs, tokens, credentials,
handles, location history, contact details) anywhere in the input fails
closed with input_rejected_forbidden_field. The real probe never emits those
fields, so their presence means the wrong input was supplied. Size cap is
256 KiB. No other file, device, or network access happens.

## Output contract (allowlist)

Only counts, coordinate-present booleans, freshness buckets, binding
availability flags, launch/build identifiers, and fixed failure codes are
emitted. Neither the expected digest nor selected_identity_digest is echoed.
Never emitted: names, coordinates, raw IDs, tokens, credentials, handles,
handles-derived strings, or location history. Unknown input keys are dropped,
never copied. Observed lanes are
cross-checked before any verdict: bucket totals must equal returned_count,
present can never exceed returned, valid and native is-old can never exceed
present, and an observed selection must carry the same aggregates with found
matching present. Anything inconsistent is rejected instead of qualified.

## Failure codes (per lane)

fresh-observed: observed with fresh coordinates (qualified).
empty-inventory: observed with returned_count 0.
absent-coordinates: observed but no location present.
decode-failure: native decode marker, or present but zero valid pairs.
stale-location: observed with coordinates but nothing fresh within 5 minutes.
not-fresh: freshness explicitly not proven (cache-only evidence).
service-auth-failure: HTTP 401 or 403 from the service.
service-http-failure: other HTTP failure (http_status preserved).
transport-failure: native transport marker.
read-failed-generic: generic failure marker.
timeout: Dart or native deadline exceeded.
no-live-session: no live reads admitted for this pass.
not-tested: not tested, no finer reason.
selection-not-requested, selection-matched-with-location,
selection-matched-no-location, selection-matched-stale-location,
selection-unmatched, selection_binding_unavailable, roster-unavailable,
no-unique-match, sole-person-unmatched.
items-not-invoked: Items deliberately never invoked (read-only default).
items-live-attempted: input claims an Items read; flagged as a violation.

Overall result mirrors the probe terminal idea: qualified-complete (People
and Devices fresh), partial (any observation), failed (both lanes failed),
not-tested otherwise.

## Safety guarantees

Default is read-only. The module imports argparse, hashlib, json, re, and sys
only. No sockets, no subprocess, no profile paths, no Apple calls. Nothing
here can change sharing, ring an item, send a message, log out, reset,
migrate, or write alignment records; those code paths do not exist here.
Parser and contract tests use synthetic fixtures only: no Apple, network, or
device operations anywhere in this folder.

## Tests

    python tooling/windows/findmy_qualification/test_findmy_qualification.py -v
