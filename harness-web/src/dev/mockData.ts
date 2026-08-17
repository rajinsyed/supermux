import type {
  ContextUsage,
  HarnessTheme,
  ModelDescriptor,
  SessionSummary
} from "../protocol/types";
import { defaultDarkTheme, defaultLightTheme } from "../ui/theme";

export function themeFor(name: string | null): HarnessTheme {
  if (name === "light") return defaultLightTheme;
  if (name === "transparent") return { ...defaultDarkTheme, pageBackground: "transparent" };
  return defaultDarkTheme;
}

const DAY = 86400000;

export function mockSessions(now = Date.now()): SessionSummary[] {
  return [
    {
      sessionId: "resumed-session-4821",
      title: "Fix sidebar scroll reset on restore",
      updatedAtMs: now - 22 * 60000,
      firstPrompt: "Why does the sidebar lose its scroll position when a workspace is restored?",
      gitBranch: "fix-sidebar-scroll",
      messageCount: 18
    },
    {
      sessionId: "session-3310",
      title: "Add harness pane protocol decoder",
      updatedAtMs: now - 5 * 3600000,
      firstPrompt: "Write a tolerant decoder for the Claude stream-json protocol",
      gitBranch: "add-harness-pane",
      messageCount: 64
    },
    {
      sessionId: "session-2884",
      title: "Investigate 100% CPU spin in session list",
      updatedAtMs: now - 1.4 * DAY,
      firstPrompt: "The sidebar spins at 100% CPU once it has 200 rows",
      gitBranch: "main",
      messageCount: 41
    },
    {
      sessionId: "session-2211",
      title: "Migrate simulator pane to shared teardown",
      updatedAtMs: now - 4 * DAY,
      firstPrompt: "Simulator stream dies when switching panes",
      gitBranch: "fix-simulator-pane",
      messageCount: 27
    },
    {
      sessionId: "session-1902",
      title: "Localize the new settings rows",
      updatedAtMs: now - 9 * DAY,
      firstPrompt: "Audit Localizable.xcstrings for missing ja translations",
      gitBranch: "main",
      messageCount: 12
    }
  ];
}

/**
 * The catalog a persisted `initialize` response would carry — keyed by SELECTOR,
 * with `resolvedModel` holding the id `system/init` reports, exactly as the live
 * CLI answers. Anything else and the cached rows fail to resolve the active
 * model the same way the live ones do.
 */
export function mockModels(): ModelDescriptor[] {
  return [
    {
      value: "opus",
      resolvedModel: "claude-opus-5",
      displayName: "Opus 5",
      description: "Most capable. Best for hard reasoning and large refactors.",
      supportsEffort: true,
      supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"],
      defaultEffortLevel: "high"
    },
    {
      value: "sonnet",
      resolvedModel: "claude-sonnet-5",
      displayName: "Sonnet 5",
      description: "Balanced speed and capability. Recommended default.",
      supportsEffort: true,
      supportedEffortLevels: ["low", "medium", "high"],
      defaultEffortLevel: "medium",
      supportsFastMode: true
    },
    {
      value: "haiku",
      resolvedModel: "claude-haiku-4-5-20251001",
      displayName: "Haiku 4.5",
      description: "Fastest and cheapest. Good for small edits.",
      supportsFastMode: true
    }
  ];
}

export function mockContextUsage(totalTokens: number, maxTokens = 200000): ContextUsage {
  const system = 1420;
  const tools = 8600;
  const messages = Math.max(0, totalTokens - system - tools);
  return {
    totalTokens,
    maxTokens,
    percentage: Math.round((totalTokens / maxTokens) * 100),
    autoCompactThreshold: Math.round(maxTokens * 0.835),
    isAutoCompactEnabled: true,
    model: "claude-sonnet-5",
    categories: [
      { name: "System prompt", tokens: system },
      { name: "System tools", tokens: tools },
      { name: "Messages", tokens: messages },
      { name: "Autocompact buffer", tokens: 33000 },
      { name: "Free space", tokens: Math.max(0, maxTokens - totalTokens - 33000) }
    ]
  };
}

export const MOCK_FILES = [
  "src/model/transcript.ts",
  "src/model/store.ts",
  "src/ui/App.tsx",
  "src/ui/transcript/TurnView.tsx",
  "src/ui/tools/ToolCard.tsx",
  "src/protocol/types.ts",
  "Sources/Panels/Panel.swift",
  "Sources/Panels/PanelContentView.swift",
  "Sources/Workspace.swift",
  "Packages/SupermuxKit/Sources/SupermuxKit/ClaudeHarness/HarnessProtocol.swift",
  "Resources/Localizable.xcstrings",
  "SUPERMUX.md",
  "SUPERMUX-TOUCHPOINTS.md",
  "scripts/supermux-build-harness-web.sh",
  "README.md"
];
