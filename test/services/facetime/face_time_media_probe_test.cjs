const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../../..');
const native = path.join(root, 'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime');
const cached = fs.readFileSync(path.join(native, 'CachedWebview.kt'), 'utf8');
const probe = fs.readFileSync(path.join(native, 'FaceTimeMediaProbe.kt'), 'utf8');
const activity = fs.readFileSync(path.join(native, 'FaceTimeActivity.kt'), 'utf8');
function rawString(source, marker) {
  const start = source.indexOf('"""', source.indexOf(marker)) + 3;
  assert.ok(start >= 3, marker);
  return source.slice(start, source.indexOf('"""', start));
}
const bootstrap = rawString(cached, 'private val webRtcDiagnosticBootstrap');
const startScript = id => rawString(probe, 'fun startScript(').replaceAll('$requestId', id);
const readScript = id => rawString(probe, 'fun readScript(').replaceAll('$requestId', id);
const flush = () => new Promise(resolve => setImmediate(resolve));

test('activity and cached view wire the resolved probe and lifecycle guards', () => {
  assert.ok(activity.includes('cached.requestMediaEvidence { result ->'));
  assert.ok(!activity.includes('window.__obFaceTimeDiagnostics.snapshot()'));
  assert.ok(activity.includes('cached !== probeView || callUuid != probeCallId'));
  assert.ok(activity.includes('cached.mediaDocumentChanged = {'));
  assert.ok(activity.includes('it.matchesSession(link, extras.getString("callUuid"))'));
  assert.ok(cached.includes('mediaProbe.invalidate()'));
  assert.ok(cached.includes('mediaDocumentChanged?.invoke()'));
  assert.ok(cached.includes('mediaProbe.close()'));
  assert.ok(activity.includes('FaceTimeDiagnosticStage.MEDIA_PROBE, state = "sampled", evidence = evidence)'));
  const diagnostics = fs.readFileSync(path.join(native, 'FaceTimeDiagnostics.kt'), 'utf8');
  assert.ok(diagnostics.includes('log.record(stage, state, count, bytes, evidence, remoteLeave)'));
  assert.ok(diagnostics.includes('formatStage(stage, state, count, bytes, evidence, remoteLeave)'));
});

function page(origin = 'https://facetime.apple.com', iframe = false) {
  let bytes = 100;
  let nextStats;
  class Peer {
    constructor() { this.iceConnectionState = 'connected'; this.listeners = {}; }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    async getStats() {
      if (nextStats) { const wait = nextStats; nextStats = null; await wait; }
      bytes += 100;
      return new Map([['inbound', { type: 'inbound-rtp', bytesReceived: bytes }]]);
    }
  }
  const window = { RTCPeerConnection: Peer, setInterval: () => 1, clearInterval: () => {} };
  window.top = iframe ? {} : window;
  const context = vm.createContext({ window, location: { origin }, document: { querySelectorAll: () => [] } });
  vm.runInContext(bootstrap, context);
  const peer = new window.RTCPeerConnection();
  peer.listeners.track({ track: { id: 'synthetic', kind: 'audio', readyState: 'live', addEventListener() {} } });
  return {
    context,
    window,
    peer,
    // Android returns the serialized immediate result, not an awaited Promise.
    evaluate: script => JSON.stringify(vm.runInContext(script, context)),
    delayStats: promise => { nextStats = promise; },
  };
}

test('resolved advancing samples cross the same synchronous evaluateJavascript boundary', async () => {
  const p = page();
  const samples = [];
  for (const id of ['request-one', 'request-two']) {
    assert.equal(p.evaluate(startScript(id)), '"started"');
    assert.equal(p.evaluate(readScript(id)), '"pending"');
    await flush();
    const raw = p.evaluate(readScript(id));
    const sample = JSON.parse(JSON.parse(raw));
    assert.equal(sample.iceState, 'connected');
    assert.equal(sample.remoteAudioTracks, 1);
    samples.push(sample);
    assert.equal(p.evaluate(readScript(id)), 'null', 'sample is consumed only once');
  }
  assert.equal(samples[0].peerId, samples[1].peerId);
  assert.ok(samples[1].mediaBytes > samples[0].mediaBytes);
});

test('pending getStats is never returned as a ready media sample', async () => {
  const p = page();
  let resolve;
  p.delayStats(new Promise(done => { resolve = done; }));
  p.evaluate(startScript('delayed'));
  await flush();
  assert.equal(p.evaluate(readScript('delayed')), '"pending"');
  resolve();
  await flush();
  assert.equal(JSON.parse(JSON.parse(p.evaluate(readScript('delayed')))).mediaBytes, 200);
});

test('a peer closed during getStats cannot hide the remaining live peer', async () => {
  for (const rejectStats of [false, true]) {
    const p = page();
    const closingPeer = new p.window.RTCPeerConnection();
    let settleStats;
    closingPeer.getStats = () => new Promise((resolve, reject) => {
      settleStats = () => rejectStats
        ? reject(new Error('synthetic closed peer'))
        : resolve(new Map([['inbound', { type: 'inbound-rtp', bytesReceived: 900 }]]));
    });

    p.evaluate(startScript('closing-peer'));
    await flush();
    assert.equal(p.evaluate(readScript('closing-peer')), '"pending"');
    closingPeer.iceConnectionState = 'closed';
    closingPeer.listeners.iceconnectionstatechange();
    settleStats();
    await flush();

    const first = JSON.parse(JSON.parse(p.evaluate(readScript('closing-peer'))));
    assert.equal(first.peerId, 1, 'closed peer must not replace live media evidence');
    assert.equal(first.iceState, 'connected');
    assert.equal(first.remoteAudioTracks, 1);

    p.evaluate(startScript('remaining-peer'));
    await flush();
    const second = JSON.parse(JSON.parse(p.evaluate(readScript('remaining-peer'))));
    assert.equal(second.peerId, first.peerId);
    assert.ok(second.mediaBytes > first.mediaBytes, 'live peer retains advancing evidence');
  }
});

test('a sampled peer closed during a later peer await cannot win on stale byte progress', async () => {
  const p = page();
  await p.window.__obFaceTimeDiagnostics.snapshot(); // establish peer 1's byte baseline
  const replacement = new p.window.RTCPeerConnection();
  let resolveStats;
  replacement.getStats = () => new Promise(resolve => { resolveStats = resolve; });
  replacement.listeners.track({
    track: { id: 'replacement', kind: 'audio', readyState: 'live', addEventListener() {} },
  });
  p.evaluate(startScript('replacement'));
  await flush();
  p.peer.iceConnectionState = 'closed';
  p.peer.listeners.iceconnectionstatechange();
  resolveStats(new Map([['inbound', { type: 'inbound-rtp', bytesReceived: 50 }]]));
  await flush();

  const sample = JSON.parse(JSON.parse(p.evaluate(readScript('replacement'))));
  assert.equal(sample.peerId, 2, 'closed peer byte progress must not outrank its replacement');
  assert.equal(sample.iceState, 'connected');
  assert.equal(sample.remoteAudioTracks, 1);
  assert.equal(sample.mediaBytes, 50);
  assert.equal(Object.hasOwn(sample, 'peer'), false, 'peer objects stay inside the probe');
});

test('a late previous request cannot replace the new request mailbox', async () => {
  const p = page();
  let resolve;
  p.delayStats(new Promise(done => { resolve = done; }));
  p.evaluate(startScript('old'));
  await flush();
  p.evaluate(startScript('new'));
  await flush();
  resolve();
  await flush();
  assert.equal(p.evaluate(readScript('old')), 'null');
  assert.equal(JSON.parse(JSON.parse(p.evaluate(readScript('new')))).mediaBytes, 200);
});

for (const origin of ['http://facetime.apple.com', 'https://facetime.apple.com.attacker.invalid', 'null']) {
  test('untrusted origin is rejected: ' + origin, () => {
    const p = page(origin);
    assert.equal(p.evaluate(startScript('blocked')), '"blocked"');
    assert.equal(p.evaluate(readScript('blocked')), 'null');
    assert.equal(p.window.__obFaceTimeMediaProbe, undefined);
  });
}

test('even a same-origin subframe cannot submit media evidence', () => {
  const p = page('https://facetime.apple.com', true);
  assert.equal(p.evaluate(startScript('frame')), '"blocked"');
  assert.equal(p.evaluate(readScript('frame')), 'null');
});

test('navigation cannot export an outstanding result to another origin or document', async () => {
  const p = page();
  p.evaluate(startScript('navigation'));
  p.context.location.origin = 'https://other.invalid';
  await flush();
  assert.equal(p.evaluate(readScript('navigation')), 'null');
  const replacement = page();
  assert.equal(replacement.evaluate(readScript('navigation')), 'null');
});

test('missing and rejected diagnostic snapshots resolve to unavailable, not connection', async () => {
  for (const diagnostics of [undefined, { snapshot: async () => { throw new Error('synthetic'); } }]) {
    const p = page();
    p.window.__obFaceTimeDiagnostics = diagnostics;
    p.evaluate(startScript('missing'));
    await flush();
    assert.equal(p.evaluate(readScript('missing')), 'null');
  }
});
