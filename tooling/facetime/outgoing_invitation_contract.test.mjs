import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

// Source contracts only. Rust behavioral tests live beside the production
// predicate; this runner neither compiles native code nor exercises IDS.
const source = fs.readFileSync(new URL("../../rustpush/src/facetime.rs", import.meta.url), "utf8");
const prop = source.slice(source.indexOf("pub async fn prop_up_conv("), source.indexOf("pub async fn decline_invite("));

function assertInvitationGuard(prop) {
  const lookup = prop.lastIndexOf("get_participants_targets(");
  // rustfmt may wrap the condition; token order, not line layout, is the contract.
  const guardPattern = /if\s+ring\s*&&\s*!has_remote_invitation_target\(/g;
  guardPattern.lastIndex = Math.max(0, lookup);
  const guard = guardPattern.exec(prop)?.index ?? -1;
  const send = prop.indexOf(".send_message(", lookup);
  const success = prop.indexOf("session.is_propped = true;");
  assert.ok(lookup >= 0 && guard > lookup && send > guard && success > send,
    "ringing must reject self-only/no-op routes before sending or marking the session propped");
  const gate = prop.slice(guard, send);
  assert.match(gate, /&my_participant\.handle/);
  assert.match(gate, /&self_token/);
  assert.match(gate, /targets\.iter\(\)/);
  assert.match(gate, /target\.participant\.as_str\(\)/);
  assert.match(gate, /target\.delivery_data\.push_token\.as_slice\(\)/);
  assert.match(gate, /return Err\(PushError::NoValidTargets\);/);
}

test("outgoing invitation checks effective remote targets before dispatch and success", () => {
  assertInvitationGuard(prop);
  assertInvitationGuard(prop.replace(/if\s+ring\s*&&\s*!has_remote_invitation_target\(/,
    "if ring && !has_remote_invitation_target("));
});

test("invitation contract still rejects a missing or post-dispatch guard", () => {
  const condition = /if\s+ring\s*&&\s*!has_remote_invitation_target\(/;
  const withoutGuard = prop.replace(condition, "if unrelated_predicate(");
  assert.throws(() => assertInvitationGuard(withoutGuard), assert.AssertionError);
  const afterDispatch = withoutGuard.replace("session.is_propped = true;",
    "if ring && !has_remote_invitation_target() {} session.is_propped = true;");
  assert.throws(() => assertInvitationGuard(afterDispatch), assert.AssertionError);
});

test("guard matches both invitation selection and IDS local-token exclusion", () => {
  assert.match(source, /targets\.any\(\|\(participant, token\)\| participant != sender && token != local_token\)/);
  assert.match(prop, /if ring && target\.participant != my_participant\.handle/);
});

test("creation propagates invitation rejection through existing failure cleanup", () => {
  const create = source.slice(source.indexOf("pub async fn create_session("), source.indexOf("async fn message_session("));
  assert.match(create, /self\.prop_up_conv\(&mut session, true\)\.await\?;/);
  assert.match(create, /if let Err\(error\) = creation/);
  assert.match(create, /remove_session_if_matches/);
  assert.match(create, /return Err\(error\);/);
});
