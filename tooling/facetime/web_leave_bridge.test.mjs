import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL(
  "../../android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt",
  import.meta.url,
), "utf8");

function productionBridge() {
  const match = source.match(/private val leaveButtonBridgeScript = """\r?\n([\s\S]*?)\r?\n\s*"""\.trimIndent\(\)/);
  assert.ok(match, "production must contain the explicit Leave bridge");
  return match[1];
}

function harness() {
  const listeners = [];
  const pageHideListeners = [];
  const events = [];
  const context = vm.createContext({
    window: { addEventListener: (type, listener) => {
      assert.equal(type, "pagehide");
      pageHideListeners.push(listener);
    } },
    document: { addEventListener: (type, listener, capture) => {
      assert.equal(type, "click");
      assert.equal(capture, true);
      listeners.push(listener);
    } },
    Native: {
      leaveRequested: () => events.push("native-request"),
      leave: () => events.push("native-leave"),
    },
    onLeave: { notifyListeners: () => events.push("apple-notifier") },
  });
  const install = () => vm.runInContext(productionBridge(), context);
  install();
  return {
    context, events, listeners, install,
    click(button) {
      // Simulate delegation from a nested SVG/span, as in Apple's controls.
      const event = { target: { closest: selector => {
        assert.equal(selector, "button");
        return button;
      } } };
      for (const listener of listeners) listener(event);
      events.push("apple-click-handler");
    },
    confirm() { vm.runInContext(patchedNotifier(), context); },
    dispose() { for (const listener of pageHideListeners) listener(); },
  };
}

function button({ id = "", text = "", aria = "", disabled = false, ariaDisabled = null } = {}) {
  return {
    id, innerText: text, textContent: text, disabled,
    getAttribute: key => key === "aria-label" ? aria : key === "aria-disabled" ? ariaDisabled : null,
  };
}

function patchedNotifier() {
  let script = "this.onLeave.notifyListeners()";
  // Replay the exact production rewrite if present, rather than a copied fix.
  const rewrite = source.match(/\.replace\("this\.onLeave\.notifyListeners\(\)", ("(?:[^"\\]|\\.)*")\)/);
  if (rewrite) script = script.replaceAll("this.onLeave.notifyListeners()", JSON.parse(rewrite[1]));
  return script;
}

test("duplicate internal Apple onLeave notifications never close the Activity", () => {
  const page = harness();
  page.confirm();
  page.confirm();
  assert.deepEqual(page.events, ["apple-notifier", "apple-notifier"]);
});

test("bridge is prepended to main.js, before any Apple admission code", () => {
  assert.match(source, /return leaveButtonBridgeScript \+ webRtcDiagnosticBootstrap \+ string/);
  assert.doesNotThrow(() => new vm.Script(productionBridge()));
});

test("Join, Rejoin and non-button clicks cannot close the Activity", () => {
  const page = harness();
  for (const text of ["Join", "Rejoin", "Mute", "Leave feedback"]) page.click(button({ text }));
  page.click(null);
  page.confirm();
  assert.ok(!page.events.includes("native-leave"));
});

test("explicit Leave by stable ID works with nested targets and localized labels", () => {
  const page = harness();
  page.click(button({ id: "callcontrols-leave-button-session-banner", text: "Quitter" }));
  assert.deepEqual(page.events, ["native-request", "apple-click-handler"]);
  page.confirm();
  assert.deepEqual(page.events, ["native-request", "apple-click-handler", "native-leave", "apple-notifier"]);
});

test("label fallback supports Leave and accessible End Call controls", () => {
  for (const control of [button({ text: " Leave " }), button({ aria: "End Call" })]) {
    const page = harness();
    page.click(control);
    page.confirm();
    assert.equal(page.events.filter(event => event === "native-leave").length, 1);
  }
});

test("disabled Leave controls do not request native teardown", () => {
  const page = harness();
  for (const control of [button({ text: "Leave", disabled: true }), button({ text: "Leave", ariaDisabled: "true" })]) {
    page.click(control);
  }
  page.confirm();
  assert.ok(!page.events.includes("native-leave"));
});

test("reinstallation and repeated taps produce only one native leave", () => {
  const page = harness();
  page.install();
  assert.equal(page.listeners.length, 1);
  page.click(button({ text: "Leave" }));
  page.click(button({ text: "Leave" }));
  page.confirm();
  page.confirm();
  assert.equal(page.events.filter(event => event === "native-request").length, 1);
  assert.equal(page.events.filter(event => event === "native-leave").length, 1);
});

test("a new document can independently leave a later call", () => {
  for (let call = 0; call < 2; call++) {
    const page = harness();
    page.click(button({ text: "Leave" }));
    page.confirm();
    assert.equal(page.events.filter(event => event === "native-leave").length, 1);
  }
});

test("an explicit tap waits for delayed confirmation without suppressing Apple handlers", async () => {
  const page = harness();
  page.confirm(); // admission churn before the explicit tap
  page.click(button({ text: "Leave" }));
  await Promise.resolve();
  assert.ok(!page.events.includes("native-leave"));
  page.confirm();
  assert.equal(page.events.filter(event => event === "native-leave").length, 1);
  assert.equal(page.events.filter(event => event === "apple-notifier").length, 2);
});

test("document teardown invalidates a pending explicit leave and late notifications", () => {
  const page = harness();
  page.click(button({ text: "Leave" }));
  page.dispose();
  page.confirm();
  page.confirm();
  page.click(button({ text: "Leave" }));
  assert.ok(!page.events.includes("native-leave"));
  assert.equal(page.events.filter(event => event === "native-request").length, 1);
});

test("Activity wiring preserves explicit fallback and guards stale teardown", () => {
  const activity = fs.readFileSync(new URL(
    "../../android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt", import.meta.url,
  ), "utf8");
  const ending = activity.slice(activity.indexOf("private fun beginEndingCall()"), activity.indexOf("private fun hideControlsForPIP()"));
  assert.match(activity, /cached\.leaveRequested = \{ beginEndingCall\(\) \}/);
  assert.match(ending, /callEnding \|\| activeFaceTimeActivity !== this \|\| isFinishing \|\| isDestroyed/);
  assert.match(ending, /mainHandler\.postDelayed\(fallback, 1500\)/);
  assert.ok(!ending.includes("postDelayed(fallback, 500)"), "a JS click is not a leave confirmation");
  assert.match(ending, /activeFaceTimeActivity === this && !isFinishing && !isDestroyed/);
  assert.match(source, /if \(endPolicy\.request\(\)\) this@CachedWebview\.leaveRequested\?\.invoke\(\)/);
  assert.match(source, /if \(!endPolicy\.confirm\(\)\) return@post/);
  assert.match(source, /fun cancelCallbacks\(\) \{\s*endPolicy\.dispose\(\)/);
  assert.match(activity, /cached\.cancelCallbacks\(\)/);
});

test("native participant snapshots do not authorize speculative automatic teardown", () => {
  const root = new URL("../../", import.meta.url);
  const service = fs.readFileSync(new URL("lib/services/rustpush/rustpush_service.dart", root), "utf8");
  const leave = service.slice(service.indexOf("if (facetime is api.FTMessage_LeaveEvent) {"), service.indexOf("if (facetime is api.FTMessage_RespondedElsewhere) {"));
  assert.ok(!leave.includes('"state": "ended"'));
  const activity = fs.readFileSync(new URL("android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt", root), "utf8");
  assert.ok(!activity.includes("nativeSessionEnded"));
  const handler = fs.readFileSync(new URL("android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeCallStateHandler.kt", root), "utf8");
  assert.ok(!handler.includes('state == "ended"'));
});
