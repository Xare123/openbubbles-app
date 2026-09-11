import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

// Source contracts only. Rust behavioral tests live beside the production
// predicate; this runner neither compiles native code nor exercises IDS.
const source = fs.readFileSync(new URL("../../rustpush/src/facetime.rs", import.meta.url), "utf8");
const prop = source.slice(source.indexOf("pub async fn prop_up_conv("), source.indexOf("pub async fn decline_invite("));

test("outgoing invitation checks effective remote targets before dispatch and success", () => {
  const lookup = prop.lastIndexOf("get_participants_targets(");
  const guard = prop.indexOf("if ring && !has_remote_invitation_target(", lookup);
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
