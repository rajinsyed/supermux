import { useCallback, useEffect, useState } from "react";
import type { SlashCommandDescriptor } from "../../protocol/types";

export interface PopoverItem {
  id: string;
  label: string;
  detail?: string;
  hint?: string;
}

export type PopoverKind = "mention" | "command" | null;

export interface PopoverState {
  kind: PopoverKind;
  query: string;
  start: number;
  items: PopoverItem[];
  index: number;
}

const EMPTY: PopoverState = { kind: null, query: "", start: 0, items: [], index: 0 };

export function detectTrigger(text: string, caret: number): { kind: PopoverKind; query: string; start: number } {
  const before = text.slice(0, caret);
  const slashMatch = /(?:^|\n)\/([\w:-]*)$/.exec(before);
  if (slashMatch) {
    return { kind: "command", query: slashMatch[1], start: caret - slashMatch[1].length - 1 };
  }
  const mentionMatch = /(?:^|\s)@([^\s@]*)$/.exec(before);
  if (mentionMatch) {
    return { kind: "mention", query: mentionMatch[1], start: caret - mentionMatch[1].length - 1 };
  }
  return { kind: null, query: "", start: 0 };
}

export function useComposerPopover(
  text: string,
  caret: number,
  commands: SlashCommandDescriptor[],
  fetchFiles: (query: string) => Promise<string[]>
): { state: PopoverState; move: (delta: number) => void; reset: () => void } {
  const [state, setState] = useState<PopoverState>(EMPTY);

  useEffect(() => {
    const trigger = detectTrigger(text, caret);
    if (trigger.kind === null) {
      setState((prev) => (prev.kind === null ? prev : EMPTY));
      return;
    }
    if (trigger.kind === "command") {
      const query = trigger.query.toLowerCase();
      const items = commands
        .filter((command) => command.name.toLowerCase().includes(query))
        .slice(0, 8)
        .map((command) => ({
          id: command.name,
          label: `/${command.name}`,
          detail: command.description,
          hint: command.argumentHint
        }));
      setState({ kind: "command", query: trigger.query, start: trigger.start, items, index: 0 });
      return;
    }
    let cancelled = false;
    fetchFiles(trigger.query)
      .then((paths) => {
        if (cancelled) return;
        setState({
          kind: "mention",
          query: trigger.query,
          start: trigger.start,
          items: paths.slice(0, 10).map((path) => ({ id: path, label: path })),
          index: 0
        });
      })
      .catch(() => {
        if (!cancelled) setState(EMPTY);
      });
    return () => {
      cancelled = true;
    };
  }, [text, caret, commands, fetchFiles]);

  const move = useCallback((delta: number) => {
    setState((prev) => {
      if (prev.kind === null || prev.items.length === 0) return prev;
      const next = (prev.index + delta + prev.items.length) % prev.items.length;
      return { ...prev, index: next };
    });
  }, []);

  const reset = useCallback(() => setState(EMPTY), []);

  return { state, move, reset };
}
