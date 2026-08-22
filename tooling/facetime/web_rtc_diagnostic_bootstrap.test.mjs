import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import {
  createWebRtcDiagnosticHarness,
  loadProductionBootstrap,
} from "./web_rtc_diagnostic_harness.mjs";

test("the production WebRTC bootstrap remains JavaScript-parseable", () => {
  const bootstrap = loadProductionBootstrap();
  assert.doesNotThrow(() => new vm.Script(bootstrap));
  assert.match(bootstrap, /RTCPeerConnection/);
  assert.match(bootstrap, /__obFaceTimeDiagnostics/);
});

test("a stale connected peer does not mask the current failed peer", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(100) },
    { iceConnectionState: "failed", stats: harnessStats(0) },
  ]);
  harness.peers[0].addRemoteTrack(harness.createTrack("stale-audio", "audio"));

  const snapshot = await harness.snapshot();

  assert.equal(snapshot.iceState, "failed");
  assert.equal(snapshot.remoteAudioTracks, 0);
  assert.equal(snapshot.mediaBytes, 0);
});

test("closed peers are removed from the active snapshot", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(100) },
    { iceConnectionState: "checking", stats: harnessStats(0) },
  ]);
  harness.peers[0].addRemoteTrack(harness.createTrack("closed-video", "video"));
  harness.peers[0].iceConnectionState = "closed";

  const snapshot = await harness.snapshot();

  assert.equal(snapshot.iceState, "checking");
  assert.equal(snapshot.remoteVideoTracks, 0);
  assert.equal(snapshot.mediaBytes, 0);
});

test("ended remote tracks disappear from later snapshots", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(64) },
  ]);
  const audio = harness.peers[0].addRemoteTrack(harness.createTrack("remote-audio", "audio"));
  const video = harness.peers[0].addRemoteTrack(harness.createTrack("remote-video", "video"));

  assert.deepEqual(await harness.snapshot(), {
    peerId: 1,
    iceState: "connected",
    remoteAudioTracks: 1,
    remoteVideoTracks: 1,
    mediaBytes: 64,
    webLeaveVisible: false,
  });

  audio.end();
  video.end();
  const snapshot = await harness.snapshot();
  assert.equal(snapshot.remoteAudioTracks, 0);
  assert.equal(snapshot.remoteVideoTracks, 0);
});

test("local outbound bytes are excluded from inbound media evidence", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    {
      iceConnectionState: "connected",
      stats: [
        { type: "inbound-rtp", bytesReceived: 25 },
        { type: "outbound-rtp", bytesSent: 100000 },
      ],
    },
  ]);
  harness.peers[0].addRemoteTrack(harness.createTrack("remote-audio", "audio"));

  const snapshot = await harness.snapshot();

  assert.equal(snapshot.mediaBytes, 25);
});

test("the current active peer is selected instead of aggregating every peer", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(100) },
    { iceConnectionState: "connected", stats: harnessStats(7) },
  ]);
  harness.peers[0].addRemoteTrack(harness.createTrack("old-audio", "audio"));
  harness.peers[1].addRemoteTrack(harness.createTrack("current-video", "video"));

  const snapshot = await harness.snapshot();

  assert.equal(snapshot.remoteAudioTracks, 0);
  assert.equal(snapshot.remoteVideoTracks, 1);
  assert.equal(snapshot.mediaBytes, 7);
  assert.equal(snapshot.peerId, 2);
});

test("advancing inbound media selects its peer without aggregating stale peers", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(100) },
    { iceConnectionState: "failed", stats: harnessStats(0) },
  ]);
  harness.peers[0].addRemoteTrack(harness.createTrack("active-video", "video"));

  const first = await harness.snapshot();
  assert.equal(first.peerId, 2);
  assert.equal(first.iceState, "failed");

  harness.peers[0].stats = harnessStats(150);
  const advancing = await harness.snapshot();
  assert.equal(advancing.peerId, 1);
  assert.equal(advancing.iceState, "connected");
  assert.equal(advancing.mediaBytes, 150);
  assert.equal(advancing.remoteVideoTracks, 1);
});

test("a reset counter is not considered advancing peer activity", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(100) },
    { iceConnectionState: "checking", stats: harnessStats(0) },
  ]);
  await harness.snapshot();
  harness.peers[0].stats = harnessStats(1);

  const snapshot = await harness.snapshot();
  assert.equal(snapshot.peerId, 2);
  assert.equal(snapshot.iceState, "checking");
});

function harnessStats(inboundBytes) {
  return [{ type: "inbound-rtp", bytesReceived: inboundBytes }];
}
