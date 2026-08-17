import type { ProtocolLine } from "../../protocol/types";
import { richSessionRaw } from "./richSessionRaw";
import { permissionFixture } from "./permission";
import { questionFixture, questionMultiFixture } from "./question";
import { planFixture } from "./plan";
import { interruptFixture } from "./interrupt";
import { errorsFixture } from "./errors";
import { compactFixture } from "./compact";
import { queueFixture } from "./queue";
import { subagentsFixture } from "./subagents";
import { todosFixture } from "./todos";
import { thinkingFixture } from "./thinking";
import { longformFixture } from "./longform";
import { resumeFixture } from "./resume";
import { rewindHistory } from "./rewind";

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

export const richSession: ProtocolLine[] = parseJsonl(richSessionRaw);

export const fixtures: Record<string, ProtocolLine[]> = {
  rich: richSession,
  streaming: richSession,
  permission: permissionFixture,
  question: questionFixture,
  questionMulti: questionMultiFixture,
  plan: planFixture,
  interrupt: interruptFixture,
  errors: errorsFixture,
  compact: compactFixture,
  queue: queueFixture,
  subagents: subagentsFixture,
  todos: todosFixture,
  thinking: thinkingFixture,
  longform: longformFixture,
  resume: resumeFixture,
  rewind: rewindHistory
};
