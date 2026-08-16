import type {
  ContextUsage,
  EffortLevel,
  HarnessContext,
  HarnessTheme,
  NativeEvent,
  PermissionMode,
  PermissionSuggestion,
  ProtocolLine,
  SessionSummary
} from "./protocol/types";

export interface ImagePayload {
  mediaType: string;
  dataBase64: string;
  name?: string;
}

export interface HarnessBridge {
  context(): Promise<HarnessContext>;
  listSessions(params?: { limit?: number }): Promise<{ sessions: SessionSummary[] }>;
  loadSessionHistory(params: { sessionId: string }): Promise<{ events: ProtocolLine[]; truncated: boolean }>;
  start(params?: {
    resumeSessionId?: string;
    forkSession?: boolean;
    model?: string;
    permissionMode?: PermissionMode;
    effort?: EffortLevel;
  }): Promise<{ runId: string }>;
  send(params: { text: string; images?: ImagePayload[]; uuid: string }): Promise<{ sent: boolean }>;
  interrupt(params: { cancelQueued: boolean }): Promise<void>;
  cancelQueued(params: { messageUuid: string }): Promise<void>;
  stop(): Promise<void>;
  setModel(params: { model: string; effort?: EffortLevel }): Promise<void>;
  setPermissionMode(params: { mode: PermissionMode }): Promise<void>;
  respondPermission(params: {
    requestId: string;
    behavior: "allow" | "deny";
    updatedInput?: unknown;
    updatedPermissions?: PermissionSuggestion[];
    message?: string;
    interrupt?: boolean;
  }): Promise<void>;
  renameSession(params: { title: string }): Promise<void>;
  getContextUsage(): Promise<ContextUsage>;
  fileSuggestions(params: { query: string }): Promise<{ paths: string[] }>;
  pickFiles(): Promise<{ images: ImagePayload[]; paths: string[] }>;
  openFile(params: { path: string; line?: number }): Promise<void>;
  copyText(params: { text: string }): Promise<void>;
  notify(params: { title: string; body: string }): Promise<void>;
  saveDraft(params: { text: string }): Promise<void>;
}

export interface BridgeError {
  code: string;
  userMessage: string;
}

export class HarnessBridgeError extends Error {
  readonly code: string;
  constructor(error: BridgeError) {
    super(error.userMessage);
    this.name = "HarnessBridgeError";
    this.code = error.code;
  }
}

interface WebkitHandler {
  postMessage(message: unknown): Promise<unknown>;
}

interface HarnessGlobal {
  receiveBatch(events: NativeEvent[]): void;
  applyTheme(theme: HarnessTheme): void;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { supermuxHarness?: WebkitHandler } };
    supermuxHarness?: HarnessGlobal;
    supermuxHarnessMock?: HarnessBridge;
  }
}

let requestCounter = 0;

function nativeHandler(): WebkitHandler | undefined {
  return window.webkit?.messageHandlers?.supermuxHarness;
}

export function hasNativeBridge(): boolean {
  return nativeHandler() !== undefined;
}

async function callNative<T>(method: string, params?: unknown): Promise<T> {
  const handler = nativeHandler();
  if (!handler) throw new HarnessBridgeError({ code: "no_bridge", userMessage: "Native bridge unavailable" });
  requestCounter += 1;
  const raw = await handler.postMessage({ id: `req-${requestCounter}`, method, params: params ?? {} });
  const envelope = raw as { ok?: boolean; value?: T; error?: BridgeError } | undefined;
  if (!envelope || envelope.ok !== true) {
    throw new HarnessBridgeError(
      envelope?.error ?? { code: "unknown", userMessage: "The request failed." }
    );
  }
  return envelope.value as T;
}

const nativeBridge: HarnessBridge = {
  context: () => callNative("harness.context"),
  listSessions: (params) => callNative("harness.listSessions", params),
  loadSessionHistory: (params) => callNative("harness.loadSessionHistory", params),
  start: (params) => callNative("harness.start", params),
  send: (params) => callNative("harness.send", params),
  interrupt: (params) => callNative("harness.interrupt", params),
  cancelQueued: (params) => callNative("harness.cancelQueued", params),
  stop: () => callNative("harness.stop"),
  setModel: (params) => callNative("harness.setModel", params),
  setPermissionMode: (params) => callNative("harness.setPermissionMode", params),
  respondPermission: (params) => callNative("harness.respondPermission", params),
  renameSession: (params) => callNative("harness.renameSession", params),
  getContextUsage: () => callNative("harness.getContextUsage"),
  fileSuggestions: (params) => callNative("harness.fileSuggestions", params),
  pickFiles: () => callNative("harness.pickFiles"),
  openFile: (params) => callNative("harness.openFile", params),
  copyText: (params) => callNative("harness.copyText", params),
  notify: (params) => callNative("harness.notify", params),
  saveDraft: (params) => callNative("harness.saveDraft", params)
};

export function getBridge(): HarnessBridge {
  if (hasNativeBridge()) return nativeBridge;
  const mock = window.supermuxHarnessMock;
  if (mock) return mock;
  throw new HarnessBridgeError({
    code: "no_bridge",
    userMessage: "No harness bridge is available in this context."
  });
}

export function installReceiver(handlers: {
  onBatch(events: NativeEvent[]): void;
  onTheme(theme: HarnessTheme): void;
}): void {
  window.supermuxHarness = {
    receiveBatch: (events) => {
      if (!Array.isArray(events)) return;
      handlers.onBatch(events);
      for (const event of events) {
        if (event && event.kind === "theme") handlers.onTheme(event.theme);
      }
    },
    applyTheme: (theme) => handlers.onTheme(theme)
  };
}
