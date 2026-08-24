/**
 * Classification of the MACHINE-AUTHORED user records Claude Code writes into a
 * session transcript. On resume these come back through `loadSessionHistory`
 * as ordinary `user` lines whose content is raw XML-ish markup, and rendering
 * them as chat bubbles is the round-5 screenshot: bubbles literally containing
 * `<command-name>/model</command-name>`, wide bubbles of
 * `<local-command-stdout>…</local-command-stdout>`, a caveat preamble, and
 * `<task-notification>` payloads. None of these is the user speaking, so none
 * of them may render as a user message.
 *
 * The shapes here mirror the real JSONL (verified against
 * `~/.claude/projects/…/f9a177ef….jsonl` and a sweep of every project dir):
 *  - `<command-name>/model</command-name>\n<command-message>…</command-message>\n<command-args>opus[1m]</command-args>`
 *  - `<local-command-stdout>Set model to opus[1m] (claude-opus-5[1m])</local-command-stdout>`
 *  - `<local-command-caveat>Caveat: The messages below were generated…</local-command-caveat>`
 *  - `Base directory for this skill: …` followed by the loaded skill body
 *  - `<task-notification>\n<task-id>…</task-id>…`
 *  - `[Request interrupted by user]` / `[Request interrupted by user for tool use]`
 *  - `This session is being continued from a previous conversation…` (the
 *    compact summary, flagged `isCompactSummary` on disk — a flag the history
 *    mapper does not forward, so the text prefix is the only signal here).
 */

export type LocalUserText =
  /** The record is a slash-command invocation: render as a command chip. */
  | { kind: "command"; name: string; args?: string }
  /** A local command's output: render as a dim result line, never a bubble. */
  | { kind: "commandOutput"; text: string }
  /** Scaffolding the user never wrote and never needs to see: hide entirely. */
  | { kind: "hidden" }
  /** The user interrupted the previous turn: mark it aborted, no bubble. */
  | { kind: "interrupt" }
  /** A compact-summary continuation preamble: render as a divider. */
  | { kind: "continued" }
  /** An ordinary user message. */
  | { kind: "plain" };

/**
 * CSI color/style sequences the CLI embeds in stdout ("\x1b[2m…"). The leading
 * escape byte (a literal ESC in this source) is REQUIRED in the pattern: the
 * user's real selectors contain a literal "[1m]" ("opus[1m]" is opus with the
 * 1M-context suffix), and an escape-less `\[[0-9;]*m` would eat it out of
 * "Set model to opus[1m]".
 */
// eslint-disable-next-line no-control-regex
const ANSI = /\[[0-9;]*m/g;

export function stripAnsi(text: string): string {
  return text.replace(ANSI, "");
}

function tagContent(text: string, tag: string): string | undefined {
  const match = text.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
  return match ? match[1] : undefined;
}

const CONTINUED_PREFIX = "This session is being continued from a previous conversation";
const SKILL_PAYLOAD_PREFIX = "Base directory for this skill:";

export function classifyLocalUserText(raw: string): LocalUserText {
  const text = raw.trimStart();
  if (text.startsWith(SKILL_PAYLOAD_PREFIX)) return { kind: "hidden" };
  if (text.startsWith("<local-command-caveat>")) return { kind: "hidden" };
  if (text.startsWith("<task-notification>")) return { kind: "hidden" };
  if (text.startsWith("<system-reminder>")) return { kind: "hidden" };
  if (text.startsWith("[Request interrupted")) return { kind: "interrupt" };
  if (text.startsWith(CONTINUED_PREFIX)) return { kind: "continued" };
  // Tag order varies by CLI version: newer transcripts open with
  // <command-name>, older ones with <command-message> (seen in the headball
  // project's mission sessions). Either way the record IS the command.
  if (text.startsWith("<command-name>") || text.startsWith("<command-message>")) {
    const name = stripAnsi(tagContent(text, "command-name") ?? "").trim();
    const args = stripAnsi(tagContent(text, "command-args") ?? "").trim();
    if (name.length === 0) return { kind: "hidden" };
    return { kind: "command", name, args: args.length > 0 ? args : undefined };
  }
  if (text.startsWith("<local-command-stdout>") || text.startsWith("<local-command-stderr>")) {
    const body =
      tagContent(text, "local-command-stdout") ?? tagContent(text, "local-command-stderr") ?? "";
    const cleaned = stripAnsi(body).trim();
    if (cleaned.length === 0) return { kind: "hidden" };
    return { kind: "commandOutput", text: cleaned };
  }
  return { kind: "plain" };
}
