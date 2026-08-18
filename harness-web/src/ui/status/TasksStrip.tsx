import { memo, useEffect, useRef, useState, type ReactNode } from "react";
import { getBridge } from "../../bridge";
import type { CopyKey } from "../../copyKeys";
import type { BackgroundTask, TaskRecord, WorkflowAgent } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import {
  AlertTriangle,
  Box,
  CheckCircle,
  ChevronDown,
  ChevronRight,
  Layers,
  Map as MapIcon,
  Stop,
  Terminal
} from "../Icons";
import { formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { SubagentTranscriptView } from "../tools/SubagentTranscript";
import { TaskOutputView } from "../tools/TaskOutput";
import { STATE_LABELS } from "../tools/WorkflowCard";

const TYPE_LABELS: Record<string, CopyKey> = {
  local_bash: "supermux.harness.tasks.typeShell",
  local_agent: "supermux.harness.tasks.typeAgent",
  local_workflow: "supermux.harness.tasks.typeWorkflow"
};

/**
 * The SDK's task_type set is explicitly extensible, so an unrecognised value is
 * admitted as a generic task — a neutral box and "Task" — rather than asserted
 * to be a shell, which is a lie the moment the CLI adds a new type.
 */
function typeIcon(type: string | undefined): ReactNode {
  if (type === "local_workflow") return <MapIcon size={11} />;
  if (type === "local_agent") return <Layers size={11} />;
  if (type === "local_bash") return <Terminal size={11} />;
  return <Box size={11} />;
}

function typeClass(type: string | undefined): string {
  return type !== undefined && type in TYPE_LABELS ? `is-${type}` : "is-unknown";
}

const SETTLED = new Set(["completed", "failed", "killed", "stopped"]);

/**
 * A settled row's outcome, as a glyph plus catalog copy — never the raw wire
 * token, which is lowercase English protocol vocabulary. An unknown terminal
 * status (a future `paused`, say) degrades to a neutral "Settled" instead of
 * leaking onto the screen.
 */
function SettledStatus({ status }: { status: string | undefined }) {
  const copy = useCopy();
  if (status === "failed") {
    return (
      <span className="task-status is-failed">
        <AlertTriangle size={10} />
        {copy("supermux.harness.tasks.statusFailed")}
      </span>
    );
  }
  if (status === "killed" || status === "stopped") {
    return (
      <span className="task-status is-stopped">
        <Stop size={9} />
        {copy("supermux.harness.tasks.statusStopped")}
      </span>
    );
  }
  if (status === "completed") {
    return (
      <span className="task-status is-done">
        <CheckCircle size={10} />
        {copy("supermux.harness.tasks.statusDone")}
      </span>
    );
  }
  return <span className="task-status">{copy("supermux.harness.tasks.statusSettled")}</span>;
}

/**
 * The workflow row's View. A workflow ROOT has no transcript file — only its
 * agents do, at workflows/<runId>/agent-<id>.jsonl — so requesting one is a
 * bridge call the native side rightly rejects. What the row CAN show is the
 * same agent list the card shows: pick an agent, drill into it by runId+agentId.
 */
function WorkflowTaskDetail({
  record,
  running
}: {
  record: TaskRecord | undefined;
  running: boolean;
}) {
  const copy = useCopy();
  const [openAgent, setOpenAgent] = useState<number | undefined>(undefined);
  const workflow = record?.workflow;
  const runId = record?.workflowRunId ?? workflow?.runId;
  const agents: WorkflowAgent[] = workflow?.agents ?? [];
  const drillable = agents.filter((agent) => agent.agentId !== undefined);

  if (!runId || drillable.length === 0) {
    return (
      <div className="drill-status">
        {running
          ? copy("supermux.harness.workflow.starting")
          : copy("supermux.harness.workflow.noAgents")}
      </div>
    );
  }

  return (
    <div className="task-wf-agents">
      <div className="task-wf-hint">{copy("supermux.harness.workflow.viewAgents")}</div>
      <ul className="task-wf-list">
        {drillable.map((agent) => {
          const open = openAgent === agent.index;
          return (
            <li key={agent.index} className="task-wf-agent">
              {/* The card's row grammar minus the metrics: the state chip says
                  the state, the label says the name in the pane's name voice.
                  The picker is the same object seen from a different place, so
                  a name swallowed into an uppercase status pill — coloured by
                  state — would read as three tags, not three things to open. */}
              <button
                type="button"
                className="wf-agent-toggle"
                onClick={() => setOpenAgent(open ? undefined : agent.index)}
                aria-expanded={open}
              >
                {open ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
                <span className={`wf-state is-${agent.state}`}>
                  {agent.state === "running" ? <Spinner size={9} /> : null}
                  {copy(STATE_LABELS[agent.state])}
                </span>
                <span className="wf-agent-label">{agent.label}</span>
              </button>
              <Disclosure open={open} className="subagent-drill">
                <SubagentTranscriptView
                  target={{ workflowRunId: runId, agentId: agent.agentId }}
                  label={agent.label}
                  open={open}
                  tick={agent.state === "running" ? record?.progressTick : undefined}
                />
              </Disclosure>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function TaskRow({
  task,
  record,
  open,
  onToggle
}: {
  task: BackgroundTask;
  record?: TaskRecord;
  open: boolean;
  onToggle(): void;
}) {
  const copy = useCopy();
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);

  const type = record?.taskType ?? task.taskType;
  const status = record?.status ?? task.status;
  const running = status === undefined || !SETTLED.has(status);
  const description =
    record?.description ?? task.description ?? copy("supermux.harness.tasks.untitled");
  // While the task runs the CLI reports what it is doing right now; that is the
  // line worth showing under the name, not the name again.
  const activity = running ? record?.activity ?? record?.lastToolName : record?.summary;
  // Only agents and workflows have transcripts; a shell — and any task type this
  // build does not recognise — has, at most, an output file to tail.
  const detailIsWorkflow = type === "local_workflow";
  const detailIsTranscript = type === "local_agent";

  const metrics: string[] = [];
  const tokens = record?.totalTokens ?? task.totalTokens;
  if (tokens) metrics.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(tokens) }));

  const stop = () => {
    setBusy(true);
    setFailed(false);
    getBridge()
      .stopTask({ taskId: task.taskId })
      .catch(() => setFailed(true))
      .finally(() => setBusy(false));
  };

  return (
    <li className={`task-row${running ? " is-running" : ""}`}>
      <div className="task-row-head">
        <span
          className={`task-type ${typeClass(type)}`}
          title={copy(TYPE_LABELS[type ?? ""] ?? "supermux.harness.tasks.typeTask")}
        >
          {typeIcon(type)}
        </span>
        <span className="task-identity">
          <span className="task-name" title={description}>
            {description}
          </span>
          {activity ? <span className="task-activity">{activity}</span> : null}
        </span>
        {metrics.length > 0 ? <span className="task-metrics tnum">{metrics.join(" · ")}</span> : null}
        {running ? (
          <>
            <Elapsed className="task-elapsed tnum" startedAtMs={record?.startedAtMs ?? Date.now()} />
            <Spinner size={10} />
          </>
        ) : (
          <SettledStatus status={status} />
        )}
        <button
          type="button"
          className="btn btn-quiet task-action"
          onClick={onToggle}
          aria-expanded={open}
        >
          {open ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
          {open ? copy("supermux.harness.tasks.hide") : copy("supermux.harness.tasks.view")}
        </button>
        {running ? (
          <button
            type="button"
            className="btn btn-quiet is-danger task-action"
            onClick={stop}
            disabled={busy}
          >
            <Stop size={10} />
            {busy ? copy("supermux.harness.tasks.stopping") : copy("supermux.harness.tasks.stop")}
          </button>
        ) : null}
      </div>
      {failed ? <div className="task-error">{copy("supermux.harness.tasks.stopFailed")}</div> : null}
      <Disclosure open={open} className="task-detail">
        {detailIsWorkflow ? (
          <WorkflowTaskDetail record={record} running={running} />
        ) : detailIsTranscript ? (
          <SubagentTranscriptView
            target={{ taskId: task.taskId }}
            open={open}
            tick={running ? record?.progressTick : undefined}
          />
        ) : (
          /* A shell's output is a FILE the CLI never streams, so viewing it
             means tailing that file. Unknown task types get the same generic
             tail — the one detail every task can have. */
          <TaskOutputView taskId={task.taskId} running={running} />
        )}
      </Disclosure>
    </li>
  );
}

/**
 * The CLI's `/tasks` panel: everything running outside the current turn.
 *
 * Membership is `model.backgroundTasks` — fed only by `background_tasks_changed`
 * — so it is empty exactly when the CLI says nothing is in the background, and
 * the strip disappears entirely rather than sitting there as an empty header.
 * Detail comes from `tasksById`, which is what lets a row keep reporting live
 * status long after its launching turn has settled and folded.
 */
export const TasksStrip = memo(function TasksStrip({
  tasks,
  tasksById
}: {
  tasks: BackgroundTask[];
  tasksById: Record<string, TaskRecord>;
}) {
  const copy = useCopy();
  const [open, setOpen] = useState(true);
  // At most one detail is expanded at a time: two open output tails on a capped
  // 220px list means neither is readable and the second is clipped mid-header.
  const [openTaskId, setOpenTaskId] = useState<string | undefined>(undefined);
  const listRef = useRef<HTMLUListElement>(null);
  const [hiddenBelow, setHiddenBelow] = useState(0);

  /**
   * The list is height-capped (the composer must survive eight shells), and a
   * silent clip hides live rows. Count the rows whose top edge is below the
   * fold and say so; the count doubles as the trigger for the fade mask.
   */
  useEffect(() => {
    const list = listRef.current;
    if (!list || !open) {
      setHiddenBelow(0);
      return;
    }
    const measure = () => {
      if (list.scrollHeight - list.clientHeight <= 2) {
        setHiddenBelow(0);
        return;
      }
      const fold = list.scrollTop + list.clientHeight;
      let below = 0;
      for (const child of Array.from(list.children)) {
        const node = child as HTMLElement;
        // A row counts as hidden when any of it is cut by the fold — the
        // critic's screenshot was a row sliced mid-content, not one fully out
        // of view, and that row too needs announcing.
        if (node.offsetTop + node.offsetHeight > fold + 2) below += 1;
      }
      setHiddenBelow(below);
    };
    measure();
    list.addEventListener("scroll", measure, { passive: true });
    // The list's own height is CAPPED, so growth happens inside it (a row's
    // detail expanding) without ever resizing the list — observe the rows too,
    // or an opening output tail clips silently.
    const observer =
      typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : undefined;
    observer?.observe(list);
    for (const child of Array.from(list.children)) observer?.observe(child);
    return () => {
      list.removeEventListener("scroll", measure);
      observer?.disconnect();
    };
  }, [open, tasks.length, openTaskId]);

  if (tasks.length === 0) return null;

  return (
    <div
      className="tasks-strip"
      // Escape closes the focused detail popover FIRST — matching Modal and
      // PermissionCard — instead of being swallowed while focus sits on a row
      // button. Handled here (where focus actually is) and stopped, so it never
      // falls through to the composer's interrupt while a popover is open.
      onKeyDown={(event) => {
        if (event.key !== "Escape" || openTaskId === undefined) return;
        event.preventDefault();
        event.stopPropagation();
        setOpenTaskId(undefined);
      }}
    >
      <button
        type="button"
        className="tasks-strip-head"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
      >
        {open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
        <span className="tasks-strip-title">{copy("supermux.harness.tasks.title")}</span>
        <span className="tasks-strip-count tnum">
          {plural(copy, tasks.length, "supermux.harness.tasks.countOne", "supermux.harness.tasks.count")}
        </span>
        <span className="sr-only">
          {open ? copy("supermux.harness.tasks.collapse") : copy("supermux.harness.tasks.expand")}
        </span>
      </button>
      <Disclosure open={open}>
        <div className={`tasks-list-frame${hiddenBelow > 0 ? " is-clipped" : ""}`}>
          <ul className="tasks-list" ref={listRef}>
            {tasks.map((task) => (
              <TaskRow
                key={task.taskId}
                task={task}
                record={tasksById[task.taskId]}
                open={openTaskId === task.taskId}
                onToggle={() =>
                  setOpenTaskId((current) => (current === task.taskId ? undefined : task.taskId))
                }
              />
            ))}
          </ul>
          {hiddenBelow > 0 ? (
            <button
              type="button"
              className="tasks-more tnum"
              onClick={() => {
                listRef.current?.scrollBy({
                  top: listRef.current.clientHeight * 0.8,
                  behavior: "smooth"
                });
              }}
            >
              <ChevronDown size={10} />
              {copy("supermux.harness.tasks.moreBelow", { count: hiddenBelow })}
            </button>
          ) : null}
        </div>
      </Disclosure>
    </div>
  );
});
