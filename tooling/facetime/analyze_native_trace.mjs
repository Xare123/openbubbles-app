import fs from "node:fs";
import { pathToFileURL } from "node:url";

// Offline only. Accept the native writer's content-free format, never echo input,
// paths, timestamps, peer ordinals, exception bodies, or unknown field values.
const stages = new Set("webview_loaded js_patched permissions_requested permissions_result admission_requested admitted ice_state remote_audio_track remote_video_track media_bytes media_lost leave lifecycle close_reason media_probe".split(" "));
const closeReasons = new Set(["native_end_fallback", "web_leave", "declined", "ring_timeout"]);
const iceStates = new Set("new checking connected completed disconnected failed closed unknown".split(" "));
const maxInputBytes = 1024 * 1024;
const integer = value => /^\d+$/.test(value ?? "") && Number.isSafeInteger(Number(value)) ? Number(value) : null;

export function analyzeNativeTrace(text) {
  const result = { schema: 1, acceptedRecords: 0, ignoredLines: 0, segments: [] };
  let segment, baseline, lastTime;
  const start = (created = false) => {
    baseline = null;
    segment = {
      created, admissionRequested: false, admittedMarker: false,
      resolvedSamples: 0, advancingPairs: 0, terminal: null,
      orderingValid: true,
    };
    result.segments.push(segment);
  };
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const match = line.match(/^time_ms=(\d+) stage=([a-z_]+)((?: [a-z]+=[a-z0-9_]+)*)$/);
    if (!match || integer(match[1]) === null || !stages.has(match[2])) {
      result.ignoredLines++;
      baseline = null; // Unknown records cannot bridge a proof of media progress.
      continue;
    }
    const fields = Object.fromEntries(match[3].trim().split(" ").filter(Boolean).map(item => item.split("=")));
    const stage = match[2], time = Number(match[1]);
    if (!segment || (stage === "lifecycle" && fields.state === "created")) {
      start(stage === "lifecycle" && fields.state === "created");
    }
    result.acceptedRecords++;
    if (lastTime !== undefined && time < lastTime) {
      segment.orderingValid = false;
      baseline = null;
    }
    lastTime = time;
    if (stage === "admission_requested" && !segment.terminal &&
      ["answer", "outgoing", "clicked", "already_joined"].includes(fields.state)) {
      if (!segment.admissionRequested) baseline = null;
      segment.admissionRequested = true; // Signaling only, not media admission.
    }
    if (stage === "admitted" && fields.state === "true") segment.admittedMarker = true;
    if (stage === "close_reason" && closeReasons.has(fields.state)) {
      if (!closeReasons.has(segment.terminal)) segment.terminal = fields.state;
      baseline = null;
    }
    if (stage === "lifecycle" && ["destroyed", "configuration_destroyed", "finishing_destroyed", "accepted"].includes(fields.state)) {
      baseline = null;
      // Destruction without a close reason is observable, but not a cause.
      if (fields.state !== "accepted") segment.terminal ??= fields.state;
    }
    if (stage !== "media_probe") continue;
    if (fields.state !== "sampled") { baseline = null; continue; }
    const peer = integer(fields.peer), bytes = integer(fields.bytes);
    const audio = integer(fields.audio), video = integer(fields.video);
    if (!iceStates.has(fields.ice) || audio === null || video === null || audio > 65535 || video > 65535) {
      baseline = null;
      continue;
    }
    segment.resolvedSamples++;
    // Only pairs wholly after the admission request establish post-admission progress.
    const valid = segment.admissionRequested && !segment.terminal && segment.orderingValid && peer > 0 && bytes > 0 &&
      ["connected", "completed"].includes(fields.ice) && (audio > 0 || video > 0);
    if (valid && baseline?.peer === peer && time > baseline.time && bytes > baseline.bytes) {
      segment.advancingPairs++;
    }
    baseline = valid ? { peer, bytes, time } : null;
  }
  for (const item of result.segments) {
    item.mediaProgressionObserved = item.advancingPairs > 0;
    item.captureComplete = item.created && item.admissionRequested &&
      closeReasons.has(item.terminal) && item.orderingValid;
  }
  // This is evidence sufficiency, never a "FaceTime fixed" verdict. A complete
  // capture may still show a failed call. No identities exist to merge sessions.
  return result;
}

export function main(args) {
  if (args.length !== 1 || args[0] === "--help") {
    console.log("Usage: node tooling/facetime/analyze_native_trace.mjs <local-facetime-native.log>\nOffline, read-only, one chronological native log only. No calls, credentials, network, or output files. Exit 0: complete lifecycle capture (created -> admission request -> explicit close), not a working call; 2: missing lifecycle evidence; 1: invalid/unreadable input. Media progression is reported separately and counts only post-admission-request pairs. Inspect rotated generations separately; never merge unrelated calls.");
    return args[0] === "--help" ? 0 : 1;
  }
  try {
    const stat = fs.statSync(args[0]);
    if (!stat.isFile() || stat.size > maxInputBytes) throw new Error();
    const report = analyzeNativeTrace(fs.readFileSync(args[0], "utf8"));
    console.log(JSON.stringify(report, null, 2));
    return report.segments.some(segment => segment.captureComplete) ? 0 : 2;
  } catch {
    console.error("Unable to read a local native trace (regular file, maximum 1 MiB required).");
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}
