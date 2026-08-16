import { memo } from "react";
import type { Block } from "../../model/types";
import { useCopy } from "../CopyContext";
import { AlertTriangle, Info, Scissors, XCircle } from "../Icons";
import { formatTokens } from "../format";
import { Markdown } from "../primitives/Markdown";
import { ToolCard } from "../tools/ToolCard";
import { ThinkingBlockView } from "./ThinkingBlockView";

function DividerView({ block }: { block: Extract<Block, { kind: "divider" }> }) {
  const copy = useCopy();
  const label =
    block.variant === "compact"
      ? copy("supermux.harness.divider.compact")
      : copy("supermux.harness.divider.reset");
  return (
    <div className="divider" role="separator">
      <span className="divider-line" />
      <span className="divider-label">
        <Scissors size={11} />
        {label}
        {block.preTokens ? (
          <span className="divider-sub tnum">
            {copy("supermux.harness.divider.compactTokens", { tokens: formatTokens(block.preTokens) })}
          </span>
        ) : null}
      </span>
      <span className="divider-line" />
    </div>
  );
}

function NoticeView({ block }: { block: Extract<Block, { kind: "notice" }> }) {
  const Icon = block.level === "error" ? XCircle : block.level === "warning" ? AlertTriangle : Info;
  return (
    <div className={`notice is-${block.level}`}>
      <Icon size={13} className="notice-icon" />
      <div className="notice-body">
        {block.title ? <div className="notice-title">{block.title}</div> : null}
        <Markdown text={block.text} />
      </div>
    </div>
  );
}

export const BlockView = memo(function BlockView({ block }: { block: Block }) {
  switch (block.kind) {
    case "text":
      return (
        <div className={`assistant-text${block.streaming ? " is-streaming" : ""}`}>
          <Markdown text={block.text} streaming={block.streaming} />
        </div>
      );
    case "thinking":
      return <ThinkingBlockView block={block} />;
    case "tool":
      return <ToolCard block={block} />;
    case "divider":
      return <DividerView block={block} />;
    case "notice":
      return <NoticeView block={block} />;
    case "image":
      return (
        <img
          className="block-image"
          src={`data:${block.mediaType};base64,${block.dataBase64}`}
          alt=""
        />
      );
    default:
      return null;
  }
});
