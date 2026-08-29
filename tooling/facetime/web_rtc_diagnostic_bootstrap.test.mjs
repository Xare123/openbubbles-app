import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import {
  createWebRtcDiagnosticHarness,
  loadProductionBootstrap,
  loadProductionControlScript,
} from "./web_rtc_diagnostic_harness.mjs";

test("the production WebRTC bootstrap remains JavaScript-parseable", () => {
  const bootstrap = loadProductionBootstrap();
  assert.doesNotThrow(() => new vm.Script(bootstrap));
  assert.match(bootstrap, /RTCPeerConnection/);
  assert.match(bootstrap, /__obFaceTimeDiagnostics/);
  assert.match(bootstrap, /window\.top !== window\.self/);
});

test("the production bridge is not installed in subframes", async () => {
  const harness = await createWebRtcDiagnosticHarness([], { topLevel: false });

  assert.equal(harness.window.__obFaceTimeDiagnostics, undefined);
  assert.equal(harness.window.__obFaceTimeNativeEvent, undefined);
});

test("the production Join and End control scripts remain parseable", () => {
  for (const propertyName of ["joinButtonScript", "endCallScript"]) {
    assert.doesNotThrow(() => new vm.Script(loadProductionControlScript(propertyName)));
  }
  assert.match(loadProductionControlScript("endCallScript"), /candidates\.find/);
  assert.match(loadProductionControlScript("endCallScript"), /getBoundingClientRect/);
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
    webControls: {
      join: { visible: false, enabled: false, count: 0 },
      rejoin: { visible: false, enabled: false, count: 0 },
      leave: { visible: false, enabled: false, count: 0 },
    },
  });

  audio.end();
  video.end();
  const snapshot = await harness.snapshot();
  assert.equal(snapshot.remoteAudioTracks, 0);
  assert.equal(snapshot.remoteVideoTracks, 0);
});

test("remote tracks arriving after the initial snapshot replace by id without stale removal", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(64) },
  ]);

  assert.equal((await harness.snapshot()).remoteAudioTracks, 0);

  const original = harness.peers[0].addRemoteTrack(
    harness.createTrack("remote-audio", "audio"),
  );
  assert.equal((await harness.snapshot()).remoteAudioTracks, 1);

  const replacement = harness.peers[0].addRemoteTrack(
    harness.createTrack("remote-audio", "audio"),
  );
  assert.equal((await harness.snapshot()).remoteAudioTracks, 1);

  original.end();
  assert.equal((await harness.snapshot()).remoteAudioTracks, 1);

  replacement.end();
  assert.equal((await harness.snapshot()).remoteAudioTracks, 0);
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

test("decoded media advancement selects the rendering peer before transport bytes", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    {
      iceConnectionState: "connected",
      stats: [{ type: "inbound-rtp", kind: "video", bytesReceived: 100, framesDecoded: 1 }],
    },
    {
      iceConnectionState: "connected",
      stats: [{ type: "inbound-rtp", kind: "video", bytesReceived: 1000, framesDecoded: 0 }],
    },
  ]);
  harness.peers[0].addRemoteTrack(harness.createTrack("decoded-video", "video"));
  await harness.snapshot();
  harness.peers[0].stats = [
    { type: "inbound-rtp", kind: "video", bytesReceived: 101, framesDecoded: 2 },
  ];
  harness.peers[1].stats = [
    { type: "inbound-rtp", kind: "video", bytesReceived: 2000, framesDecoded: 0 },
  ];

  const snapshot = await harness.snapshot();

  assert.equal(snapshot.peerId, 1);
  assert.equal(snapshot.videoFramesDecoded, 2);
});

test("a newer connected tracked peer supersedes an older advancing peer", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    {
      iceConnectionState: "connected",
      stats: [{ type: "inbound-rtp", kind: "video", bytesReceived: 100, framesDecoded: 1 }],
    },
    {
      iceConnectionState: "connected",
      stats: [{ type: "inbound-rtp", kind: "video", bytesReceived: 10, framesDecoded: 0 }],
    },
  ]);
  harness.peers[0].addRemoteTrack(harness.createTrack("old-video", "video"));
  harness.peers[1].addRemoteTrack(harness.createTrack("new-video", "video"));
  await harness.snapshot();
  harness.peers[0].stats = [
    { type: "inbound-rtp", kind: "video", bytesReceived: 200, framesDecoded: 2 },
  ];

  const snapshot = await harness.snapshot();

  assert.equal(snapshot.peerId, 2);
  assert.equal(snapshot.videoFramesDecoded, 0);
});

test("the DOM diagnostic distinguishes visible, hidden, and disabled Join/Rejoin/Leave controls", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(10) },
  ]);
  const buttons = [
    button("Join", { offsetParent: {} }),
    button("Rejoin", { offsetParent: null }),
    button("Leave", { offsetParent: {}, disabled: true }),
    button("end call", { offsetParent: {}, ariaDisabled: true }),
  ];
  harness.window.document.querySelectorAll = () => buttons;

  const controls = (await harness.snapshot()).webControls;

  assert.deepEqual(controls, {
    join: { visible: true, enabled: true, count: 1 },
    rejoin: { visible: false, enabled: false, count: 1 },
    leave: { visible: true, enabled: false, count: 2 },
  });
});

test("the DOM diagnostic follows Join/Rejoin/Leave mutations between snapshots", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(10) },
  ]);
  let buttons = [button("Join", { offsetParent: {} })];
  harness.window.document.querySelectorAll = () => buttons;

  assert.deepEqual((await harness.snapshot()).webControls, {
    join: { visible: true, enabled: true, count: 1 },
    rejoin: { visible: false, enabled: false, count: 0 },
    leave: { visible: false, enabled: false, count: 0 },
  });

  buttons = [
    button("Join", { offsetParent: null }),
    button("Rejoin", { offsetParent: {} }),
    button("Leave", { offsetParent: {} }),
  ];
  assert.deepEqual((await harness.snapshot()).webControls, {
    join: { visible: false, enabled: false, count: 1 },
    rejoin: { visible: true, enabled: true, count: 1 },
    leave: { visible: true, enabled: true, count: 1 },
  });

  buttons = [button("Leave", { offsetParent: {}, disabled: true })];
  assert.deepEqual((await harness.snapshot()).webControls, {
    join: { visible: false, enabled: false, count: 0 },
    rejoin: { visible: false, enabled: false, count: 0 },
    leave: { visible: true, enabled: false, count: 1 },
  });
});

test("fixed-position controls remain visible without an offset parent", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(10) },
  ]);
  harness.window.document.querySelectorAll = () => [
    button("Leave", {
      offsetParent: null,
      rectWidth: 120,
      rectHeight: 48,
      computedStyle: { display: "block", visibility: "visible", opacity: "1", position: "fixed" },
    }),
  ];

  assert.equal((await harness.snapshot()).webControls.leave.visible, true);
});

test("the mutation observer reports Leave visibility changes once per state", async () => {
  const harness = await createWebRtcDiagnosticHarness([
    { iceConnectionState: "connected", stats: harnessStats(10) },
  ]);
  let buttons = [];
  harness.window.document.querySelectorAll = () => buttons;

  assert.deepEqual(
    harness.nativeEvents.map((event) => [event.event, event.visible]),
    [["web-leave-visibility", "false"]],
  );
  buttons = [button("Leave", { offsetParent: {} })];
  harness.triggerMutation();
  harness.triggerMutation();
  buttons = [];
  harness.triggerMutation();

  assert.deepEqual(
    harness.nativeEvents.map((event) => [event.event, event.visible]),
    [
      ["web-leave-visibility", "false"],
      ["web-leave-visibility", "true"],
      ["web-leave-visibility", "false"],
    ],
  );
});

test("duplicate bootstrap installation does not double-wrap new peers", async () => {
  const harness = await createWebRtcDiagnosticHarness();
  const diagnostics = harness.window.__obFaceTimeDiagnostics;

  harness.installBootstrap();
  assert.equal(harness.window.__obFaceTimeDiagnostics, diagnostics);

  const peer = new harness.window.RTCPeerConnection();
  peer.iceConnectionState = "connected";
  peer.connectionState = "connected";
  peer.stats = harnessStats(10);

  const snapshot = await harness.snapshot();
  assert.equal(snapshot.peerId, 1);
});

function harnessStats(inboundBytes) {
  return [{ type: "inbound-rtp", bytesReceived: inboundBytes }];
}

function button(
  text,
  {
    offsetParent,
    disabled = false,
    ariaDisabled = false,
    rectWidth = offsetParent === null ? 0 : 100,
    rectHeight = offsetParent === null ? 0 : 40,
    computedStyle = { display: "block", visibility: "visible", opacity: "1" },
  },
) {
  return {
    innerText: text,
    textContent: text,
    offsetParent,
    hidden: false,
    disabled,
    computedStyle,
    getBoundingClientRect() {
      return { width: rectWidth, height: rectHeight };
    },
    getAttribute(name) {
      if (name === "aria-disabled") return ariaDisabled ? "true" : null;
      if (name === "aria-hidden") return null;
      return null;
    },
  };
}
