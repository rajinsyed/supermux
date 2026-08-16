import { memo, useState, type ReactNode } from "react";
import type { ToolBlock, ToolStatus } from "../../model/types";
import { bashExitCode } from "../../model/toolStatus";
import { useCopy } from "../CopyContext";
import {
  AlertTriangle,
  Brain,
  CheckCircle,
  ChevronDown,
  ChevronRight,
  FileEdit,
  FileText,
  Globe,
  Layers,
  List,
  Search,
  Sparkle,
  Terminal,
  XCircle
} from "../Icons";
import { formatCompactDuration } from "../format";
import { Spinner } from "../primitives/Spinner";
import { Elapsed } from "../primitives/Elapsed";
import {
  BashBody,
  EditBody,
  GenericBody,
  InteractiveBody,
  McpBody,
  ReadBody,
  SearchBody,
  TodoBody,
  WebBody,
  WriteBody,
  toolMetrics
} from "./ToolBodies";
import { diffStats } from "../primitives/DiffView";
import { SubagentCard } from "./SubagentCard";
import { toolFamily, toolHeadline, toolSubtitle, type ToolFamily } from "./toolMeta";

const ICONS: Record<ToolFamily, (props: { size?: number }) => ReactNode> = {
  interactive: Sparkle,
  bash: Terminal,
  edit: FileEdit,
  write: FileEdit,
  read: FileText,
  search: Search,
  web: Globe,
  todo: List,
  task: Layers,
  mcp: Brain,
  generic: Brain
};

function StatusMark({ status }: { status: ToolStatus }) {
  if (status === "running" || status === "pending") return <Spinner size={12} />;
  if (status === "error") return <XCircle size={13} className="mark-error" />;
  if (status === "denied" || status === "aborted") return <AlertTriangle size={13} className="mark-warn" />;
  return <CheckCircle size={13} className="mark-ok" />;
}

function bodyFor(block: ToolBlock, family: ToolFamily): ReactNode {
  switch (family) {
    case "bash":
      return <BashBody block={block} />;
    case "edit":
      return <EditBody block={block} />;
    case "write":
      return <WriteBody block={block} />;
    case "read":
      return <ReadBody block={block} />;
    case "search":
      return <SearchBody block={block} />;
    case "web":
      return <WebBody block={block} />;
    case "todo":
      return <TodoBody block={block} />;
    case "interactive":
      return <InteractiveBody block={block} />;
    case "mcp":
      return <McpBody block={block} />;
    default:
      return <GenericBody block={block} />;
  }
}

function badgesFor(block: ToolBlock, family: ToolFamily, copy: ReturnType<typeof useCopy>): ReactNode[] {
  const badges: ReactNode[] = [];
  if (family === "bash") {
    const code = bashExitCode(block.structured);
    if (code !== undefined && code !== 0) {
      badges.push(
        <span key="exit" className="tool-badge is-error tnum">
          {copy("supermux.harness.tool.exitCode", { code })}
        </span>
      );
    }
  }
  if (family === "edit" || family === "write") {
    const hunks = block.structured?.structuredPatch;
    if (Array.isArray(hunks) && hunks.length > 0) {
      const stats = diffStats(hunks as never);
      if (stats.added > 0) {
        badges.push(
          <span key="add" className="tool-badge is-add tnum">
            +{stats.added}
          </span>
        );
      }
      if (stats.removed > 0) {
        badges.push(
          <span key="del" className="tool-badge is-del tnum">
            −{stats.removed}
          </span>
        );
      }
    }
    const type = block.structured?.type;
    if (type === "create") {
      badges.push(
        <span key="new" className="tool-badge">
          {copy("supermux.harness.tool.created")}
        </span>
      );
    }
  }
  for (const metric of toolMetrics(block)) {
    badges.push(
      <span key={metric} className="tool-badge is-quiet tnum">
        {metric}
      </span>
    );
  }
  return badges;
}

function defaultOpen(block: ToolBlock, family: ToolFamily): boolean {
  if (block.status === "error") return true;
  if (family === "todo" || family === "task") return true;
  if (family === "bash") return true;
  if (family === "edit") {
    const hunks = block.structured?.structuredPatch;
    return Array.isArray(hunks) && hunks.length > 0;
  }
  return false;
}

export const ToolCard = memo(function ToolCard({
  block,
  depth = 0
}: {
  block: ToolBlock;
  depth?: number;
}) {
  const copy = useCopy();
  const family = toolFamily(block.name);
  const running = block.status === "running" || block.status === "pending";
  const [open, setOpen] = useState(() => defaultOpen(block, family));

  if (family === "task") return <SubagentCard block={block} depth={depth} />;

  const Icon = ICONS[family];
  const headline = toolHeadline(block.name, block.input);
  const subtitle = toolSubtitle(block.name, block.input);
  const badges = badgesFor(block, family, copy);
  const elapsed = block.endedAtMs !== undefined ? block.endedAtMs - block.startedAtMs : 0;
  const duration = elapsed >= 250 ? formatCompactDuration(elapsed) : undefined;

  return (
    <div className={`tool-card is-${block.status}${open ? " is-open" : ""}`} data-family={family}>
      <button
        type="button"
        className="tool-head"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
      >
        <span className="tool-caret" aria-hidden="true">
          {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
        </span>
        <span className="tool-icon">
          <Icon size={13} />
        </span>
        <span className="tool-title">
          <span className="tool-headline">{headline}</span>
          {subtitle ? <span className="tool-subtitle">{subtitle}</span> : null}
        </span>
        <span className="tool-badges">{badges}</span>
        {running ? (
          <Elapsed className="tool-elapsed tnum" startedAtMs={block.startedAtMs} />
        ) : duration ? (
          <span className="tool-elapsed tnum">{duration}</span>
        ) : null}
        <span className="tool-status">
          <StatusMark status={block.status} />
        </span>
      </button>
      {open ? bodyFor(block, family) : null}
    </div>
  );
});
