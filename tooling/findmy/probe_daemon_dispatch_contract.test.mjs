import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

// Source contract for the Find My dispatch split behind the live gap.
// Production daemon recv_wait dispatches every APS message to fmfd.handle,
// eliciting the IDS-242 secure handshake. The bounded Windows probe host
// performs roster and selected reads only and never dispatches IDS receive.
// This runner compiles no native code and touches no live profile.
const daemonSource = fs.readFileSync(
  new URL('../../rust/src/api/api.rs', import.meta.url),
  'utf8',
);
const harnessSource = fs.readFileSync(
  new URL('../../lib/cloud_sync_v2_windows_harness.dart', import.meta.url),
  'utf8',
);
const probeSource = fs.readFileSync(
  new URL('../../lib/cloud_sync_v2_windows_findmy_probe.dart', import.meta.url),
  'utf8',
);

function recvWaitBody(source) {
  const start = source.indexOf('pub async fn recv_wait(');
  assert.ok(start >= 0, 'recv_wait must exist in production daemon');
  const end = source.indexOf('fn cloud_sync_attachment_send_source(', start);
  return source.slice(start, end > start ? end : start + 20000);
}

function probeHostBody(source) {
  const open = String.fromCharCode(60);
  const close = String.fromCharCode(62);
  const def = 'Future' + open + 'void' + close + ' _runWindowsFindMyProbe()';
  const start = source.indexOf(def);
  assert.ok(start >= 0, 'Windows probe host definition must exist');
  const end = source.indexOf('cloudSyncV2WindowsHarnessStatusPayload({', start);
  return source.slice(start, end > start ? end : start + 20000);
}

test('production daemon dispatches APS to FindMy before FaceTime and iMessage', () => {
  const body = recvWaitBody(daemonSource);
  const fmfd = body.indexOf('fmfd.handle(msg.clone()).await');
  assert.ok(fmfd >= 0, 'daemon must dispatch APS to fmfd.handle');
  const ft = body.indexOf('state.ft_client.handle(msg.clone()).await');
  const im = body.indexOf('state.client.handle(msg).await');
  assert.ok(ft > fmfd, 'FindMy dispatch must precede FaceTime dispatch');
  assert.ok(im > fmfd, 'FindMy dispatch must precede iMessage dispatch');
});

test('Windows probe host never dispatches IDS receive', () => {
  const body = probeHostBody(harnessSource);
  assert.ok(body.indexOf('fmfd.handle') < 0, 'probe host must not touch fmfd');
  assert.ok(body.indexOf('FindMyClient') < 0, 'probe host must not construct FindMyClient');
  assert.ok(body.indexOf('receive_message') < 0, 'probe host must not dispatch IDS receive');
  assert.ok(body.indexOf('prepareWindowsFindMyProbeReads') >= 0, 'probe host must use roster reads');
  assert.ok(body.indexOf('runWindowsFindMyProbe') >= 0, 'probe host must use aggregate runner');
});

test('probe binding uses roster and selected native reads only', () => {
  const tokens = ['makeFindMyPhone', 'makeFindMyFriends', 'refreshDevices', 'refreshFollowing', 'selectFriend'];
  for (const token of tokens) {
    assert.ok(probeSource.indexOf(token) >= 0, 'probe binding must use ' + token);
  }
  assert.ok(probeSource.indexOf('receive_message') < 0, 'probe binding must not dispatch IDS receive');
  assert.ok(probeSource.indexOf('FindMyClient') < 0, 'probe binding must not construct FindMyClient');
});
