import type { Block, TranscriptModel } from "../model/types";
import type { CopyFn } from "./CopyContext";
import { formatCost, formatDuration } from "./format";

function renderBlocks(blocks: Block[], depth: number, out: string[]): void {
  const indent = "  ".repeat(depth);
  for (const block of blocks) {
    switch (block.kind) {
      case "text":
        out.push(block.text);
        out.push("");
        break;
      case "thinking":
        if (block.text.trim().length > 0) {
          out.push(`${indent}<details><summary>Thinking (${block.tokens} tokens)</summary>`);
          out.push("");
          out.push(block.text);
          out.push("");
          out.push(`${indent}</details>`);
          out.push("");
        }
        break;
      case "tool": {
        const status = block.status === "error" ? "failed" : block.status;
        out.push(`${indent}- **${block.name}** (${status})`);
        const input = JSON.stringify(block.input);
        if (input !== "{}") out.push(`${indent}  \`${input.slice(0, 400)}\``);
        if (block.children.length > 0) renderBlocks(block.children, depth + 1, out);
        break;
      }
      case "divider":
        out.push("---");
        out.push("");
        break;
      case "notice":
        out.push(`${indent}> ${block.text}`);
        out.push("");
        break;
      case "commandOutput":
        out.push(`${indent}> ${block.text}`);
        out.push("");
        break;
      default:
        break;
    }
  }
}

export function exportTranscript(model: TranscriptModel, copy: CopyFn): string {
  const out: string[] = [];
  out.push(`# ${model.session.title ?? copy("supermux.harness.turn.exportTitle")}`);
  out.push("");
  if (model.session.cwd) out.push(`Working directory: \`${model.session.cwd}\``);
  if (model.session.model) out.push(`Model: ${model.session.model}`);
  out.push(`Total cost: ${formatCost(model.usage.costUsd)}`);
  out.push("");

  for (const turn of model.turns) {
    if (turn.command) {
      out.push(`\`${turn.command.name}${turn.command.args ? ` ${turn.command.args}` : ""}\``);
      out.push("");
    } else if (turn.userText) {
      out.push(`## ${turn.userText.split("\n")[0].slice(0, 80)}`);
      out.push("");
      out.push(turn.userText);
      out.push("");
    }
    renderBlocks(turn.blocks, 0, out);
    if (turn.result) {
      out.push(
        `_${formatDuration(turn.result.durationMs, copy)} · ${formatCost(turn.result.costDeltaUsd)}_`
      );
      out.push("");
    }
  }
  return out.join("\n");
}
