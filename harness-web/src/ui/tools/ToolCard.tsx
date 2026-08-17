import { memo, useState, type ReactNode } from "react";
import type { CopyKey } from "../../copyKeys";
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
import { Disclosure } from "../primitives/Disclosure";
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
import { toolFamily, toolHeadline, toolSubtitle, toolSubtitleFull, type ToolFamily } from "./toolMeta";

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

const STATUS_LABELS: Record<ToolStatus, CopyKey> = {
  pending: "supermux.harness.tool.pending",
  running: "supermux.harness.tool.running",
  success: "supermux.harness.tool.succeeded",
  error: "supermux.harness.tool.failed",
  denied: "supermux.harness.tool.denied",
  aborted: "supermux.harness.tool.aborted"
};

/** The only outcome signal on a folded row was an icon with no accessible text. */
function StatusMark({ status }: { status: ToolStatus }) {
  const copy = useCopy();
  const label = copy(STATUS_LABELS[status]);
  const mark =
    status === "running" || status === "pending" ? (
      <Spinner size={12} />
    ) : status === "error" ? (
      <XCircle size={13} className="mark-error" />
    ) : status === "denied" || status === "aborted" ? (
      <AlertTriangle size={13} className="mark-warn" />
    ) : (
      <CheckCircle size={13} className="mark-ok" />
    );
  return (
    <span role="img" aria-label={label} title={label}>
      {mark}
    </span>
  );
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
            {copy("supermux.harness.tool.linesAdded", { count: stats.added })}
          </span>
        );
      }
      if (stats.removed > 0) {
        badges.push(
          <span key="del" className="tool-badge is-del tnum">
            {copy("supermux.harness.tool.linesRemoved", { count: stats.removed })}
          </span>
        );
      }
    }
    const type = block.structured?.type;
    if (type === "create" || type === "update") {
      badges.push(
        <span key="type" className="tool-badge">
          {copy(
            type === "create" ? "supermux.harness.tool.created" : "supermux.harness.tool.updated"
          )}
        </span>
      );
    }
  }
  for (const metric of toolMetrics(block, copy)) {
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
  const subtitleFull = toolSubtitleFull(block.name, block.input);
  const badges = badgesFor(block, family, copy);
  const elapsed = block.endedAtMs !== undefined ? block.endedAtMs - block.startedAtMs : 0;
  const duration = elapsed >= 250 ? formatCompactDuration(elapsed, copy) : undefined;

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
          <span className="tool-headline" title={headline}>
            {headline}
          </span>
          {subtitle ? (
            <span className="tool-subtitle" title={subtitleFull}>
              {subtitle}
            </span>
          ) : null}
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
      <Disclosure open={open}>{bodyFor(block, family)}</Disclosure>
    </div>
  );
});
