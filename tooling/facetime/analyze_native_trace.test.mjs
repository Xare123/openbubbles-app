import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { analyzeNativeTrace, main } from "./analyze_native_trace.mjs";

const sample = (bytes, peer = 1, ice = "connected", audio = 1) =>
  `media_probe state=sampled peer=${peer} ice=${ice} audio=${audio} video=0 bytes=${bytes}`;
const trace = (...events) => events.map((event, i) => `time_ms=${1000 + i * 1000} stage=${event}`).join("\n");
const run = (...events) => analyzeNativeTrace(trace(...events)).segments;
const opening = ["lifecycle state=created", "admission_requested state=answer"];
// Exact content-free field names and values emitted by FaceTimeDiagnosticPolicy.
const remoteLeave = (state = "received", active = 1, total = 2, matches = "true") =>
  `remote_leave state=${state} reason=participant_leave active=${active} total=${total} matches_active_call=${matches}`;

test("native remote-leave phases remain visible without erasing same-peer media progression", () => {
  const report = analyzeNativeTrace(trace(...opening, sample(100), remoteLeave(),
    remoteLeave("refreshed", 0), remoteLeave("refresh_failed", "unavailable", "unavailable", "unavailable"), sample(200)));
  const [s] = report.segments;
  assert.equal(s.advancingPairs, 1);
  assert.equal(report.ignoredLines, 0);
  assert.equal(report.acceptedRecords, 7);
  assert.deepEqual(s.remoteLeaveObservations, [
    { state: "received", reason: "participant_leave", active: 1, total: 2, matchesActiveCall: true },
    { state: "refreshed", reason: "participant_leave", active: 0, total: 2, matchesActiveCall: true },
    { state: "refresh_failed", reason: "participant_leave", active: null, total: null, matchesActiveCall: null },
  ]);
  assert.equal(s.terminal, null);
  assert.equal(s.captureComplete, false);
});

test("all-inactive participant observations never imply whole-session termination or call identity", () => {
  for (const matches of ["true", "false", "unavailable"]) {
    const [s] = run(...opening, remoteLeave("refreshed", 0, 0, matches));
    assert.equal(s.remoteLeaveObservations.length, 1);
    assert.equal(s.remoteLeaveObservations[0].matchesActiveCall,
      matches === "unavailable" ? null : matches === "true");
    assert.equal(s.terminal, null);
    assert.equal(s.captureComplete, false);
    assert.equal(s.mediaProgressionObserved, false);
  }
});

test("remote-leave observations stay in their log segment and preserve explicit close reasons", () => {
  const segments = run(...opening, remoteLeave(), "close_reason state=web_leave",
    remoteLeave("refreshed", 0), ...opening, sample(100));
  assert.equal(segments.length, 2);
  assert.equal(segments[0].remoteLeaveObservations.length, 2);
  assert.equal(segments[0].terminal, "web_leave");
  assert.equal(segments[0].captureComplete, true);
  assert.deepEqual(segments[1].remoteLeaveObservations, []);
  assert.equal(segments[1].terminal, null);
});

test("out-of-order remote-leave markers invalidate ordering and cannot bridge media", () => {
  const input = trace(...opening, sample(100)) + `\ntime_ms=2500 stage=${remoteLeave()}\ntime_ms=5000 stage=${sample(200)}`;
  const [s] = analyzeNativeTrace(input).segments;
  assert.equal(s.orderingValid, false);
  assert.equal(s.advancingPairs, 0);
  assert.equal(s.remoteLeaveObservations.length, 1);
});

test("remote-leave counts preserve the native bounds and independently unavailable values", () => {
  const [s] = run(remoteLeave("received", 65535, "unavailable", "false"),
    remoteLeave("refresh_failed", "unavailable", 65535));
  assert.deepEqual(s.remoteLeaveObservations.map(o => [o.active, o.total]), [[65535, null], [null, 65535]]);
  assert.equal(s.created, false);
  assert.equal(s.captureComplete, false);
});

test("remote-leave diagnostics cannot restore a baseline across media or lifecycle boundaries", () => {
  for (const boundary of ["media_probe state=document_changed", "media_probe state=unavailable",
    "lifecycle state=accepted", "lifecycle state=destroyed", "close_reason state=web_leave", sample(100, 2)]) {
    const [s] = run(...opening, sample(100), remoteLeave(), boundary, remoteLeave("refreshed", 0), sample(200));
    assert.equal(s.remoteLeaveObservations.length, 2);
    assert.equal(s.advancingPairs, 0);
  }
});

test("unknown or malformed remote-leave evidence remains private and breaks the baseline", () => {
  const secret = "synthetic_private_token";
  for (const event of [
    `unknown_stage state=${secret}`, remoteLeave(secret),
    remoteLeave().replace("participant_leave", secret), remoteLeave("received", 65536),
    remoteLeave("received", 1, "9007199254740992"), remoteLeave("received", -1),
    remoteLeave("received", 1, 2, secret), remoteLeave().replace(" active=1", ""),
    remoteLeave() + " active=0", remoteLeave() + ` private_field=${secret}`,
  ]) {
    const report = analyzeNativeTrace(trace(...opening, sample(100), event, sample(200)));
    assert.equal(report.ignoredLines, 1);
    assert.deepEqual(report.segments[0].remoteLeaveObservations, []);
    assert.equal(report.segments[0].advancingPairs, 0);
    assert.equal(report.segments[0].terminal, null);
    assert.ok(!JSON.stringify(report).includes(secret));
  }
});

test("CLI reports remote-leave evidence but still requires an explicit close", t => {
  const input = trace(...opening, remoteLeave("refreshed", 0, 0));
  t.mock.method(fs, "statSync", () => ({ isFile: () => true, size: input.length }));
  t.mock.method(fs, "readFileSync", () => input);
  const output = t.mock.method(console, "log", () => {});
  assert.equal(main(["synthetic-native-trace"]), 2);
  const report = JSON.parse(output.mock.calls[0].arguments[0]);
  assert.equal(report.segments[0].remoteLeaveObservations.length, 1);
  assert.equal(report.segments[0].terminal, null);
});

test("resolved same-peer progression plus explicit close is a complete diagnostic, not a call-success verdict", () => {
  const [s] = run(...opening, sample(100), sample(200), "admitted state=true", "close_reason state=web_leave");
  assert.equal(s.advancingPairs, 1);
  assert.equal(s.captureComplete, true);
  assert.equal(s.terminal, "web_leave");
});

test("a full failed-call span is complete without media progression", () => {
  const [s] = run(...opening, "ice_state state=failed", "close_reason state=web_leave");
  assert.equal(s.captureComplete, true);
  assert.equal(s.mediaProgressionObserved, false);
  assert.equal(s.advancingPairs, 0);
});

test("pre-admission pairs followed by request and close are not post-admission progress", () => {
  const [s] = run(opening[0], sample(100), sample(200), opening[1], "close_reason state=web_leave");
  assert.equal(s.captureComplete, true);
  assert.equal(s.mediaProgressionObserved, false);
  assert.equal(s.advancingPairs, 0);
});

test("progress requires two post-admission samples, without bridging earlier samples", () => {
  const events = [opening[0], sample(100), sample(200), opening[1], sample(300)];
  assert.equal(run(...events)[0].advancingPairs, 0);
  const [s] = run(...events, sample(400), "close_reason state=web_leave");
  assert.equal(s.advancingPairs, 1);
  assert.equal(s.mediaProgressionObserved, true);
  assert.equal(s.captureComplete, true);
});

test("a close before the admission request cannot complete a new lifecycle span", () => {
  const [s] = run(opening[0], "close_reason state=web_leave", opening[1]);
  assert.equal(s.captureComplete, false);
});

for (const event of [sample(100, 2), sample(100, 1, "failed"), sample(100, 1, "connected", 0),
  "media_probe state=unavailable", "media_probe state=document_changed", "media_probe state=exhausted",
  sample("unavailable"), sample(0), "lifecycle state=accepted"]) {
  test("cannot bridge a media baseline across " + event, () => {
    assert.equal(run(...opening, sample(100), event, sample(200))[0].advancingPairs, 0);
  });
}

test("admission, standalone counters and paused lifecycle do not prove media or termination", () => {
  const [s] = run(...opening, "admitted state=true", "media_bytes bytes=100", "media_bytes bytes=200", "lifecycle state=paused");
  assert.equal(s.mediaProgressionObserved, false);
  assert.equal(s.terminal, null);
  assert.equal(s.captureComplete, false);
});

test("created lifecycle isolates different activities despite reused peer ordinal", () => {
  const segments = run(...opening, sample(100), ...opening, sample(200));
  assert.equal(segments.length, 2);
  assert.ok(segments.every(s => !s.mediaProgressionObserved));
});

test("rotation fragments can show progress but cannot claim a complete capture", () => {
  const [s] = run(opening[1], sample(100), sample(200), "close_reason state=web_leave");
  assert.equal(s.mediaProgressionObserved, true);
  assert.equal(s.captureComplete, false);
});

test("stalled and reset byte counters do not prove progression", () => {
  for (const bytes of [100, 50, "9007199254740992"]) {
    assert.equal(run(...opening, sample(100), sample(bytes))[0].advancingPairs, 0);
  }
});

test("lifecycle destruction is not a causal close reason and later samples cannot resurrect it", () => {
  for (const state of ["destroyed", "configuration_destroyed", "finishing_destroyed"]) {
    const [s] = run(...opening, sample(100), `lifecycle state=${state}`, sample(200), sample(300));
    assert.equal(s.terminal, state);
    assert.equal(s.advancingPairs, 0);
    assert.equal(s.captureComplete, false);
  }
});

test("out-of-order or identical-time samples cannot establish progress", () => {
  for (const time of [1000, 2000]) {
    const report = analyzeNativeTrace(`time_ms=0 stage=${opening[1]}\ntime_ms=2000 stage=${sample(100)}\ntime_ms=${time} stage=${sample(200)}`);
    assert.equal(report.segments[0].advancingPairs, 0);
  }
});

test("private or malformed input is never echoed and breaks the media baseline", () => {
  const secret = "SYNTHETIC_PRIVATE_TOKEN";
  const input = trace(...opening, sample(100)) + `\n${secret}\n` + `time_ms=5000 stage=${sample(200)}\n` +
    `time_ms=6000 stage=close_reason state=${secret.toLowerCase()}`;
  const report = analyzeNativeTrace(input);
  assert.ok(!JSON.stringify(report).toLowerCase().includes(secret.toLowerCase()));
  assert.equal(report.ignoredLines, 1);
  assert.equal(report.segments[0].advancingPairs, 0);
  assert.equal(report.segments[0].terminal, null);
});

test("legacy captures without the native schema report missing evidence", () => {
  const report = analyzeNativeTrace("FaceTime admission approved\nFaceTime connected");
  assert.equal(report.acceptedRecords, 0);
  assert.deepEqual(report.segments, []);
});

test("an explicit close reason can follow lifecycle destruction", () => {
  const [s] = run(...opening, sample(100), sample(200), "lifecycle state=finishing_destroyed", "close_reason state=web_leave");
  assert.equal(s.terminal, "web_leave");
  assert.equal(s.captureComplete, true);
});

const cli = fileURLToPath(new URL("./analyze_native_trace.mjs", import.meta.url));
test("CLI exit zero means complete lifecycle, including a fully captured failed call", t => {
  const input = trace(...opening, "ice_state state=failed", "close_reason state=web_leave");
  t.mock.method(fs, "statSync", () => ({ isFile: () => true, size: input.length }));
  t.mock.method(fs, "readFileSync", () => input);
  const output = t.mock.method(console, "log", () => {});
  assert.equal(main(["synthetic-native-trace"]), 0);
  const report = JSON.parse(output.mock.calls[0].arguments[0]);
  assert.equal(report.segments[0].captureComplete, true);
  assert.equal(report.segments[0].mediaProgressionObserved, false);
});

test("Windows-compatible CLI returns missing-evidence exit code on non-native text", () => {
  const result = spawnSync(process.execPath, [cli, cli], { encoding: "utf8" });
  assert.equal(result.status, 2);
  assert.equal(JSON.parse(result.stdout).acceptedRecords, 0);
  assert.equal(result.stderr, "");
});

test("CLI errors never expose the private input path", () => {
  const result = spawnSync(process.execPath, [cli, cli + ".SYNTHETIC_PRIVATE_MISSING"], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.ok(!result.stderr.includes("SYNTHETIC_PRIVATE"));
  assert.equal(result.stdout, "");
});

test("CLI help is offline and requires no trace", () => {
  const result = spawnSync(process.execPath, [cli, "--help"], { encoding: "utf8" });
  assert.equal(result.status, 0);
  assert.match(result.stdout, /Offline, read-only/);
  assert.match(result.stdout, /Exit 0: complete lifecycle capture.*not a working call/);
  assert.match(result.stdout, /participant diagnostics, not whole-session termination/);
});
