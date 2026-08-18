import { memo } from "react";
import type { CopyKey } from "../../copyKeys";
import type { Block, NoticeErrorKind } from "../../model/types";
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

const ERROR_TITLES: Record<NoticeErrorKind, CopyKey> = {
  auth: "supermux.harness.error.auth",
  billing: "supermux.harness.error.billing",
  rateLimit: "supermux.harness.error.rateLimit",
  generic: "supermux.harness.error.generic"
};

function NoticeView({ block }: { block: Extract<Block, { kind: "notice" }> }) {
  const copy = useCopy();
  const Icon = block.level === "error" ? XCircle : block.level === "warning" ? AlertTriangle : Info;
  const title = block.title ?? (block.errorKind ? copy(ERROR_TITLES[block.errorKind]) : undefined);
  return (
    <div className={`notice is-${block.level}`}>
      <Icon size={13} className="notice-icon" />
      <div className="notice-body">
        {title ? <div className="notice-title">{title}</div> : null}
        <Markdown text={block.text} />
      </div>
    </div>
  );
}

/**
 * The user side of an agent's conversation.
 *
 * Two things arrive here and they must not look alike: the PROMPT the parent
 * wrote when it spawned this agent — which is the brief, and reads as the
 * opening of the conversation — and a message delivered to it mid-run, which is
 * someone talking to it. A pending one is a message the composer has sent and
 * the agent has not acknowledged yet; it is shown immediately, because a
 * composer that swallows what you typed until a round trip completes reads as a
 * send that failed.
 */
function ThreadUserMessage({ block }: { block: Extract<Block, { kind: "userText" }> }) {
  const copy = useCopy();
  return (
    <div
      className={`thread-user${block.prompt ? " is-prompt" : ""}${
        block.pending ? " is-pending" : ""
      }`}
    >
      {block.prompt ? (
        <div className="thread-user-label">{copy("supermux.harness.agentView.prompt")}</div>
      ) : null}
      <div className="thread-user-body">{block.text}</div>
      {block.pending ? (
        <div className="thread-user-pending">
          {copy("supermux.harness.agentView.relaySending")}
        </div>
      ) : null}
    </div>
  );
}

export const BlockView = memo(function BlockView({
  block,
  live = false
}: {
  block: Block;
  /** The block is the visible tail of a turn that is still streaming. */
  live?: boolean;
}) {
  switch (block.kind) {
    case "text":
      // An empty text block — a message that opened with a tool call, or a
      // stream segment that never received a delta — must not paint. Its
      // wrapper's margins alone read as a stray blank line between rows.
      if (block.text.trim().length === 0) return null;
      return (
        <div className={`assistant-text${block.streaming ? " is-streaming" : ""}`}>
          <Markdown text={block.text} streaming={block.streaming} />
        </div>
      );
    case "thinking":
      return <ThinkingBlockView block={block} />;
    case "tool":
      return <ToolCard block={block} live={live} />;
    case "divider":
      return <DividerView block={block} />;
    case "notice":
      return <NoticeView block={block} />;
    case "userText":
      return <ThreadUserMessage block={block} />;
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
