import { ansiControlSequenceEnd, isAnsiControlStart } from "./utf8";

export interface AnsiSpan {
  text: string;
  className?: string;
  style?: { color?: string; background?: string };
}

export interface AnsiLine {
  spans: AnsiSpan[];
}

const BASIC = [
  "ansi-black",
  "ansi-red",
  "ansi-green",
  "ansi-yellow",
  "ansi-blue",
  "ansi-magenta",
  "ansi-cyan",
  "ansi-white"
];

interface State {
  fg?: string;
  bg?: string;
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
  color?: string;
  background?: string;
}

function emptyState(): State {
  return { bold: false, dim: false, italic: false, underline: false };
}

function classNames(state: State): string | undefined {
  const parts: string[] = [];
  if (state.fg) parts.push(state.fg);
  if (state.bg) parts.push(state.bg);
  if (state.bold) parts.push("ansi-bold");
  if (state.dim) parts.push("ansi-dim");
  if (state.italic) parts.push("ansi-italic");
  if (state.underline) parts.push("ansi-underline");
  return parts.length > 0 ? parts.join(" ") : undefined;
}

function xterm256(code: number): string {
  if (code < 8) return `var(--ansi-${BASIC[code].slice(5)})`;
  if (code < 16) return `var(--ansi-bright-${BASIC[code - 8].slice(5)})`;
  if (code < 232) {
    const n = code - 16;
    const r = Math.floor(n / 36);
    const g = Math.floor((n % 36) / 6);
    const b = n % 6;
    const scale = (v: number) => (v === 0 ? 0 : 55 + v * 40);
    return `rgb(${scale(r)}, ${scale(g)}, ${scale(b)})`;
  }
  const gray = 8 + (code - 232) * 10;
  return `rgb(${gray}, ${gray}, ${gray})`;
}

function applySgr(state: State, codes: number[]): void {
  for (let i = 0; i < codes.length; i += 1) {
    const code = codes[i];
    if (code === 0) {
      const fresh = emptyState();
      state.fg = fresh.fg;
      state.bg = fresh.bg;
      state.bold = false;
      state.dim = false;
      state.italic = false;
      state.underline = false;
      state.color = undefined;
      state.background = undefined;
    } else if (code === 1) state.bold = true;
    else if (code === 2) state.dim = true;
    else if (code === 3) state.italic = true;
    else if (code === 4) state.underline = true;
    else if (code === 22) {
      state.bold = false;
      state.dim = false;
    } else if (code === 23) state.italic = false;
    else if (code === 24) state.underline = false;
    else if (code >= 30 && code <= 37) {
      state.fg = BASIC[code - 30];
      state.color = undefined;
    } else if (code === 39) {
      state.fg = undefined;
      state.color = undefined;
    } else if (code >= 40 && code <= 47) {
      state.bg = `bg-${BASIC[code - 40]}`;
      state.background = undefined;
    } else if (code === 49) {
      state.bg = undefined;
      state.background = undefined;
    } else if (code >= 90 && code <= 97) {
      state.fg = `ansi-bright-${BASIC[code - 90].slice(5)}`;
      state.color = undefined;
    } else if (code >= 100 && code <= 107) {
      state.bg = `bg-ansi-bright-${BASIC[code - 100].slice(5)}`;
      state.background = undefined;
    } else if (code === 38 || code === 48) {
      const mode = codes[i + 1];
      const isForeground = code === 38;
      if (mode === 5) {
        const value = xterm256(codes[i + 2] ?? 0);
        if (isForeground) {
          state.color = value;
          state.fg = undefined;
        } else {
          state.background = value;
          state.bg = undefined;
        }
        i += 2;
      } else if (mode === 2) {
        const value = `rgb(${codes[i + 2] ?? 0}, ${codes[i + 3] ?? 0}, ${codes[i + 4] ?? 0})`;
        if (isForeground) {
          state.color = value;
          state.fg = undefined;
        } else {
          state.background = value;
          state.bg = undefined;
        }
        i += 4;
      }
    }
  }
}

const INVISIBLE_CONTROLS = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/g;

function sgrParameters(text: string, start: number, end: number): number[] | undefined {
  const c1 = text.charCodeAt(start) === 0x9b;
  const escaped = text.charCodeAt(start) === 0x1b && text[start + 1] === "[";
  if ((!c1 && !escaped) || text[end - 1] !== "m") return undefined;
  const parametersStart = c1 ? start + 1 : start + 2;
  const raw = text.slice(parametersStart, end - 1);
  if (!/^[0-9;]*$/.test(raw)) return undefined;
  const codes = raw
    .split(";")
    .map((part) => (part === "" ? 0 : Number.parseInt(part, 10)))
    .filter((code) => Number.isFinite(code));
  return codes.length > 0 ? codes : [0];
}

export function parseAnsi(text: string, maxLines = 4000): AnsiLine[] {
  const lines: AnsiLine[] = [];
  const state = emptyState();
  let current: AnsiSpan[] = [];

  const push = (chunk: string) => {
    if (!chunk) return;
    const parts = chunk.split("\n");
    for (let index = 0; index < parts.length; index += 1) {
      if (index > 0) {
        lines.push({ spans: current });
        current = [];
        if (lines.length >= maxLines) return;
      }
      const piece = parts[index].replace(/\r/g, "").replace(INVISIBLE_CONTROLS, "");
      if (!piece) continue;
      const className = classNames(state);
      const style =
        state.color || state.background
          ? { color: state.color, background: state.background }
          : undefined;
      current.push({ text: piece, className, style });
    }
  };

  let cursor = 0;
  let index = 0;
  while (index < text.length && lines.length < maxLines) {
    const code = text.charCodeAt(index);
    if (!isAnsiControlStart(code)) {
      index += 1;
      continue;
    }

    push(text.slice(cursor, index));
    if (lines.length >= maxLines) break;
    const end = ansiControlSequenceEnd(text, index);
    if (end === undefined) {
      cursor = text.length;
      index = text.length;
      break;
    }
    const parameters = sgrParameters(text, index, end);
    if (parameters) applySgr(state, parameters);
    cursor = end;
    index = end;
  }
  if (lines.length < maxLines) push(text.slice(cursor));
  lines.push({ spans: current });
  return lines;
}

export function stripAnsi(text: string): string {
  const visible: string[] = [];
  let cursor = 0;
  let index = 0;
  while (index < text.length) {
    const code = text.charCodeAt(index);
    if (!isAnsiControlStart(code)) {
      index += 1;
      continue;
    }
    visible.push(text.slice(cursor, index));
    const end = ansiControlSequenceEnd(text, index);
    if (end === undefined) {
      cursor = text.length;
      break;
    }
    cursor = end;
    index = end;
  }
  visible.push(text.slice(cursor));
  return visible.join("").replace(INVISIBLE_CONTROLS, "");
}

export function hasAnsi(text: string): boolean {
  for (let index = 0; index < text.length; index += 1) {
    if (isAnsiControlStart(text.charCodeAt(index))) return true;
  }
  return false;
}
