import { memo, useId, type ReactNode } from "react";
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
  Map as MapIcon,
  Search,
  Sparkle,
  Terminal,
  XCircle
} from "../Icons";
import { Disclosure } from "../primitives/Disclosure";
import { Spinner } from "../primitives/Spinner";
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
import { usePresentationOverride } from "../presentationState";
import { BackgroundBashStrip, backgroundBashBadges, backgroundBashStatus } from "./BackgroundBash";
import { AgentRow } from "./AgentRow";
import { WorkflowRow } from "../workflow/WorkflowRow";
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
  workflow: MapIcon,
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
      return (
        <>
          <BashBody block={block} />
          <BackgroundBashStrip block={block} />
        </>
      );
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
    badges.push(...backgroundBashBadges(block, copy));
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

/**
 * `live` means the row is the visible tail of a turn that is still streaming.
 * Auto-expansion is suppressed there: the tail is ONE row, and letting its
 * height depend on which tool family happens to be current makes it swap
 * between a ~32px collapsed strip and a ~172px open terminal card several times
 * a second. Because the transcript is bottom-anchored, every one of those swaps
 * translates the settled text above it — measured at 9.6 shifts/second, up to
 * 132px, on `longform`. Expansion resumes the moment the turn settles, which is
 * a boundary the reader already expects to reflow.
 */
function defaultOpen(
  block: ToolBlock,
  family: ToolFamily,
  status: ToolStatus,
  live: boolean
): boolean {
  if (live) return false;
  if (status === "error") return true;
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
  depth = 0,
  live = false,
  stateKey
}: {
  block: ToolBlock;
  depth?: number;
  live?: boolean;
  stateKey?: string;
}) {
  const copy = useCopy();
  const localId = useId();
  const family = toolFamily(block.name);
  // A backgrounded Bash's tool_result lands instantly, so the block's own
  // status would paint a green check beside a "Still running" badge; its
  // chrome follows the task's status instead.
  const status = family === "bash" ? backgroundBashStatus(block) : block.status;
  // The default is re-derived rather than frozen at mount, so a card that lands
  // while its turn streams still opens once the turn settles. Even failures stay
  // compact while the turn is live; the status mark carries the outcome until
  // the reader expands it or the turn settles. A user toggle wins over both and
  // lives outside the virtual subtree.
  const [override, setOverride] = usePresentationOverride(
    `${stateKey ?? `tool:${block.key || localId}`}:open`
  );
  const open = override ?? defaultOpen(block, family, status, live);

  // An agent's whole record in the transcript is ONE row too: the conversation
  // it had is read in its own full-chat view, not unrolled inline under the
  // turn that spawned it. Nested spawns show as indented rows so the SHAPE of
  // the tree is visible here without descending into it.
  if (family === "task") return <AgentRow block={block} />;
  // A workflow's whole record in the transcript is ONE row; the run itself is
  // browsed in a full multi-pane view (src/ui/workflow), the way the CLI does
  // it, rather than unrolled inline into 600px of nested disclosures.
  if (family === "workflow") return <WorkflowRow block={block} />;

  const Icon = ICONS[family];
  const headline = toolHeadline(block.name, block.input, copy);
  const subtitle = toolSubtitle(block.name, block.input);
  const subtitleFull = toolSubtitleFull(block.name, block.input);
  const badges = badgesFor(block, family, copy);

  return (
    <div className={`tool-card is-${status}${open ? " is-open" : ""}`} data-family={family}>
      <button
        type="button"
        className="tool-head"
        onClick={() => setOverride(!open)}
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
        <span className="tool-status">
          <StatusMark status={status} />
        </span>
      </button>
      <Disclosure open={open}>{bodyFor(block, family)}</Disclosure>
    </div>
  );
});
