import type { ProtocolLine } from "../../protocol/types";

/**
 * Its own module rather than a member of `index.ts`: the round-3 fixtures need
 * it and `index.ts` imports them, so keeping it there would make the two files
 * import each other.
 */
export function parseJsonl(text: string): ProtocolLine[] {
  const lines: ProtocolLine[] = [];
  for (const raw of text.split("\n")) {
    const trimmed = raw.trim();
    if (!trimmed) continue;
    try {
      lines.push(JSON.parse(trimmed) as ProtocolLine);
    } catch {
      // tolerate truncated trailing lines
    }
  }
  return lines;
}
