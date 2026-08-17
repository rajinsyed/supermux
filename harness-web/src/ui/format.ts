import type { CopyFn } from "./CopyContext";

/**
 * Every unit label here is a catalog string, not a hardcoded suffix: Japanese
 * writes durations as 2分14秒, so "2m 14s" assembled in code can never be
 * translated no matter what the catalog says.
 */
export function formatDuration(ms: number | undefined, copy: CopyFn): string {
  const total = ms === undefined || !Number.isFinite(ms) || ms < 0 ? 0 : ms;
  const totalSeconds = Math.round(total / 1000);
  if (totalSeconds < 60) return copy("supermux.harness.time.seconds", { value: totalSeconds });
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  if (minutes < 60) {
    return copy("supermux.harness.time.minutes", {
      value: minutes,
      seconds: seconds.toString().padStart(2, "0")
    });
  }
  const hours = Math.floor(minutes / 60);
  return copy("supermux.harness.time.hours", {
    value: hours,
    minutes: (minutes % 60).toString().padStart(2, "0")
  });
}

export function formatCompactDuration(ms: number | undefined, copy: CopyFn): string {
  if (ms === undefined || !Number.isFinite(ms)) return "";
  if (ms < 1000) {
    return copy("supermux.harness.tool.durationMs", { count: Math.max(1, Math.round(ms)) });
  }
  return formatDuration(ms, copy);
}

export function formatTokens(count: number | undefined): string {
  if (count === undefined || !Number.isFinite(count)) return "0";
  if (count < 1000) return String(Math.round(count));
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  return `${(count / 1000000).toFixed(1)}M`;
}

export function formatCost(usd: number | undefined): string {
  if (usd === undefined || !Number.isFinite(usd) || usd <= 0) return "$0.00";
  if (usd < 0.01) return `$${usd.toFixed(4)}`;
  if (usd < 1) return `$${usd.toFixed(3)}`;
  return `$${usd.toFixed(2)}`;
}

export function formatRelativeTime(ms: number, copy: CopyFn, nowMs = Date.now()): string {
  const delta = Math.max(0, nowMs - ms);
  const minutes = Math.floor(delta / 60000);
  if (minutes < 1) return copy("supermux.harness.time.justNow");
  if (minutes < 60) return copy("supermux.harness.time.minutesAgo", { value: minutes });
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return copy("supermux.harness.time.hoursAgo", { value: hours });
  const days = Math.floor(hours / 24);
  if (days < 30) return copy("supermux.harness.time.daysAgo", { value: days });
  return new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

export function basename(path: string): string {
  const cleaned = path.replace(/\/+$/, "");
  const slash = cleaned.lastIndexOf("/");
  return slash === -1 ? cleaned : cleaned.slice(slash + 1);
}

export function shortenPath(path: string, maxSegments = 3): string {
  const parts = path.split("/").filter(Boolean);
  if (parts.length <= maxSegments) return path.startsWith("/") ? `/${parts.join("/")}` : parts.join("/");
  return `…/${parts.slice(-maxSegments).join("/")}`;
}

export function displayDirectory(path: string | undefined): string {
  if (!path) return "";
  const home = "/Users/";
  if (path.startsWith(home)) {
    const rest = path.slice(home.length);
    const slash = rest.indexOf("/");
    if (slash >= 0) return `~${rest.slice(slash)}`;
    return "~";
  }
  return path;
}

const EXT_LANGUAGE: Record<string, string> = {
  ts: "typescript",
  tsx: "typescript",
  js: "javascript",
  jsx: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  json: "json",
  swift: "swift",
  py: "python",
  rb: "ruby",
  go: "go",
  rs: "rust",
  java: "java",
  kt: "kotlin",
  c: "c",
  h: "c",
  cc: "cpp",
  cpp: "cpp",
  hpp: "cpp",
  m: "objectivec",
  mm: "objectivec",
  cs: "csharp",
  php: "php",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  fish: "bash",
  yml: "yaml",
  yaml: "yaml",
  toml: "ini",
  ini: "ini",
  md: "markdown",
  markdown: "markdown",
  html: "xml",
  xml: "xml",
  svg: "xml",
  css: "css",
  scss: "scss",
  sql: "sql",
  diff: "diff",
  patch: "diff"
};

export function languageForPath(path: string | undefined): string {
  if (!path) return "plaintext";
  const dot = path.lastIndexOf(".");
  if (dot === -1) return "plaintext";
  return EXT_LANGUAGE[path.slice(dot + 1).toLowerCase()] ?? "plaintext";
}

export function truncateMiddle(text: string, max: number): string {
  if (text.length <= max) return text;
  const half = Math.floor((max - 1) / 2);
  return `${text.slice(0, half)}…${text.slice(text.length - half)}`;
}

export function countLines(text: string | undefined): number {
  if (!text) return 0;
  let count = 1;
  for (let i = 0; i < text.length; i += 1) if (text.charCodeAt(i) === 10) count += 1;
  return count;
}

export function approximateTokens(text: string): number {
  return Math.ceil(text.length / 3.8);
}
