import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const cachedWebviewSource = path.resolve(
  process.cwd(),
  "android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt",
);
const faceTimeActivitySource = path.resolve(
  process.cwd(),
  "android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt",
);

function kotlinTrimIndent(value) {
  const lines = value.replace(/\r\n/g, "\n").split("\n");
  while (lines.length > 0 && lines[0].trim() === "") lines.shift();
  while (lines.length > 0 && lines.at(-1).trim() === "") lines.pop();

  const indentation = lines
    .filter((line) => line.trim() !== "")
    .map((line) => line.match(/^\s*/)[0].length);
  const minimumIndent = indentation.length > 0 ? Math.min(...indentation) : 0;
  return lines.map((line) => line.slice(Math.min(minimumIndent, line.length))).join("\n");
}

export function loadProductionBootstrap(sourcePath = cachedWebviewSource) {
  const source = fs.readFileSync(sourcePath, "utf8");
  const match = source.match(
    /private val webRtcDiagnosticBootstrap = """\r?\n([\s\S]*?)\r?\n\s*"""\.trimIndent\(\)/,
  );
  if (!match) throw new Error("CachedWebview.kt no longer contains the embedded WebRTC bootstrap");
  return kotlinTrimIndent(match[1]);
}

export function loadProductionControlScript(propertyName, sourcePath = faceTimeActivitySource) {
  const source = fs.readFileSync(sourcePath, "utf8");
  const escapedName = propertyName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = source.match(
    new RegExp(`private val ${escapedName} = """\\r?\\n([\\s\\S]*?)\\r?\\n\\s*"""\\.trimIndent\\(\\)`),
  );
  if (!match) throw new Error(`FaceTimeActivity.kt no longer contains ${propertyName}`);
  return kotlinTrimIndent(match[1]);
}

class FakeTrack {
  constructor(id, kind) {
    this.id = id;
    this.kind = kind;
    this.readyState = "live";
    this.listeners = new Map();
  }

  addEventListener(name, callback) {
    const callbacks = this.listeners.get(name) ?? [];
    callbacks.push(callback);
    this.listeners.set(name, callbacks);
  }

  end() {
    this.readyState = "ended";
    for (const callback of this.listeners.get("ended") ?? []) callback();
  }
}

class FakePeer {
  static pendingConfigurations = [];

  constructor() {
    const configuration = FakePeer.pendingConfigurations.shift() ?? {};
    this.iceConnectionState = configuration.iceConnectionState ?? "new";
    this.connectionState = configuration.connectionState ?? this.iceConnectionState;
    this.stats = configuration.stats ?? [];
    this.listeners = new Map();
  }

  addEventListener(name, callback) {
    const callbacks = this.listeners.get(name) ?? [];
    callbacks.push(callback);
    this.listeners.set(name, callbacks);
  }

  emit(name, event = {}) {
    for (const callback of this.listeners.get(name) ?? []) callback(event);
  }

  addRemoteTrack(track) {
    this.emit("track", { track });
    return track;
  }

  async getStats() {
    const reports = [...this.stats];
    return { forEach: (callback) => reports.forEach(callback) };
  }
}

function stats(bytesReceived = null, bytesSent = null) {
  const reports = [];
  if (bytesReceived !== null) reports.push({ type: "inbound-rtp", bytesReceived });
  if (bytesSent !== null) reports.push({ type: "outbound-rtp", bytesSent });
  return reports;
}

export async function createWebRtcDiagnosticHarness(
  peerConfigurations = [],
  { topLevel = true } = {},
) {
  FakePeer.pendingConfigurations = peerConfigurations.map((configuration) => ({ ...configuration }));
  const nativeEvents = [];
  let mutationCallback = null;
  const window = {
    RTCPeerConnection: FakePeer,
    setInterval: () => 1,
    clearInterval: () => {},
    getComputedStyle: (element) => element.computedStyle ?? {
      display: "block",
      visibility: "visible",
      opacity: "1",
    },
    addEventListener: () => {},
    MutationObserver: class {
      constructor(callback) {
        mutationCallback = callback;
      }

      observe() {}
    },
  };
  window.self = window;
  window.top = topLevel ? window : {};
  const document = {
    documentElement: {},
    querySelectorAll: () => [],
    addEventListener: () => {},
  };
  window.document = document;
  const Native = {
    leave: (token) => nativeEvents.push({ event: "leave", token }),
    mirrored: (token) => nativeEvents.push({ event: "mirrored", token }),
    mediaEvidence: (token, probeId, payload) =>
      nativeEvents.push({ event: "media-evidence", token, probeId, payload }),
    webLeaveVisibility: (token, visible) =>
      nativeEvents.push({ event: "web-leave-visibility", token, visible }),
  };
  const context = vm.createContext({
    window,
    document,
    Native,
    console,
  });
  const bootstrap = loadProductionBootstrap();
  new vm.Script(bootstrap, { filename: "CachedWebview.webRtcDiagnosticBootstrap.js" }).runInContext(context);

  const peers = peerConfigurations.map(() => new window.RTCPeerConnection());
  return {
    bootstrap,
    window,
    peers,
    nativeEvents,
    stats,
    createTrack: (id, kind) => new FakeTrack(id, kind),
    installBootstrap: () => {
      new vm.Script(bootstrap, { filename: "CachedWebview.webRtcDiagnosticBootstrap.js" }).runInContext(context);
    },
    triggerMutation: () => mutationCallback?.(),
    snapshot: () => window.__obFaceTimeDiagnostics.snapshot().then((raw) => JSON.parse(raw)),
  };
}
