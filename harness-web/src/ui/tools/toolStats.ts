import type { SubagentToolStats } from "../../model/types";
import { plural, type CopyFn } from "../CopyContext";

/**
 * What an agent actually DID, from `AgentOutput.toolStats` — the one summary
 * the CLI computes and the pane would otherwise throw away.
 *
 * Ordered by what a reader scans for first: what CHANGED, then what was merely
 * looked at. Its home is the agent's own view now that the inline surface is a
 * single row; it was written for the round-3 card and moved rather than
 * rewritten, because the ordering argument is the same wherever it renders.
 */
export function toolStatsSummary(stats: SubagentToolStats, copy: CopyFn): string[] {
  const out: string[] = [];
  if (stats.editFileCount) {
    out.push(
      plural(
        copy,
        stats.editFileCount,
        "supermux.harness.subagent.filesEditedOne",
        "supermux.harness.subagent.filesEdited"
      )
    );
  }
  if (stats.linesAdded || stats.linesRemoved) {
    out.push(
      copy("supermux.harness.subagent.lineDelta", {
        added: stats.linesAdded ?? 0,
        removed: stats.linesRemoved ?? 0
      })
    );
  }
  if (stats.readCount) {
    out.push(
      plural(
        copy,
        stats.readCount,
        "supermux.harness.subagent.filesReadOne",
        "supermux.harness.subagent.filesRead"
      )
    );
  }
  if (stats.searchCount) {
    out.push(
      plural(
        copy,
        stats.searchCount,
        "supermux.harness.subagent.searchesOne",
        "supermux.harness.subagent.searches"
      )
    );
  }
  if (stats.bashCount) {
    out.push(
      plural(
        copy,
        stats.bashCount,
        "supermux.harness.subagent.commandsOne",
        "supermux.harness.subagent.commands"
      )
    );
  }
  if (stats.otherToolCount) {
    out.push(
      plural(
        copy,
        stats.otherToolCount,
        "supermux.harness.subagent.otherToolsOne",
        "supermux.harness.subagent.otherTools"
      )
    );
  }
  return out;
}
