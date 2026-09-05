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
