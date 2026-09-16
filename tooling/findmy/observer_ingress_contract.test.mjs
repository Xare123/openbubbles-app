import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

// Source contract for the queued redelivery-safe IDS observation ingress.
// The ingress must decrypt through the verified path and observe only:
// no acknowledgement, no token import, no itemsharing branches, no CloudKit.
// This runner compiles no native code and touches no live profile.
const source = fs.readFileSync(
  new URL('../../rustpush/src/findmy.rs', import.meta.url),
  'utf8',
);

function ingressBody() {
  const name = 'observe_ids_message_redelivery_safe';
  const attr = source.indexOf('allow(dead_code)');
  assert.ok(attr >= 0, 'queued ingress must carry allow(dead_code)');
  const start = source.indexOf(name, attr);
  assert.ok(start > attr, 'queued ingress must exist');
  assert.ok(source.indexOf(name, start + name.length) < 0, 'ingress must have no callers yet');
  const end = source.indexOf('pub async fn handle(', start);
  assert.ok(end > start, 'production handler must follow the ingress');
  return source.slice(attr, end);
}

test('ingress decrypts through the verified path and observes', () => {
  const body = ingressBody();
  for (const token of ['receive_message', 'observe_ids242_single_pass', 'allow(dead_code)', 'findmy_242_wire_had_plaintext', 'alloy.fmf', 'alloy.fmd']) {
    assert.ok(body.indexOf(token) >= 0, 'ingress must contain ' + token);
  }
});

test('ingress performs no acknowledgement, import, mutation, or CloudKit work', () => {
  const body = ingressBody();
  for (const token of ['do_app_ack', 'add_shared_item', 'delete_shared_item', 'get_container', 'with_cloudkit_writer_operation', 'sync_items', 'ItemSharingMessage', 'itemsharing-crossaccount', 'send_message']) {
    assert.ok(body.indexOf(token) < 0, 'ingress must not contain ' + token);
  }
});
