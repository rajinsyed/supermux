import { memo, useState, type ReactNode } from "react";
import { getBridge } from "../../bridge";
import type { CopyKey } from "../../copyKeys";
import type { BackgroundTask, TaskRecord } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight, Layers, Map as MapIcon, Stop, Terminal } from "../Icons";
import { formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { SubagentTranscriptView } from "../tools/SubagentTranscript";
import { TaskOutputView } from "../tools/TaskOutput";

const TYPE_LABELS: Record<string, CopyKey> = {
  local_bash: "supermux.harness.tasks.typeShell",
  local_agent: "supermux.harness.tasks.typeAgent",
  local_workflow: "supermux.harness.tasks.typeWorkflow"
};

function typeIcon(type: string | undefined): ReactNode {
  if (type === "local_workflow") return <MapIcon size={11} />;
  if (type === "local_agent") return <Layers size={11} />;
  return <Terminal size={11} />;
}

const SETTLED = new Set(["completed", "failed", "killed", "stopped"]);

function TaskRow({ task, record }: { task: BackgroundTask; record?: TaskRecord }) {
  const copy = useCopy();
  const [open, setOpen] = useState(false);
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
  const shell = type === "local_bash" || type === undefined;

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
        <span className={`task-type is-${type ?? "local_bash"}`} title={copy(TYPE_LABELS[type ?? "local_bash"] ?? "supermux.harness.tasks.typeShell")}>
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
          <span className="task-status">{status}</span>
        )}
        <button
          type="button"
          className="btn btn-quiet task-action"
          onClick={() => setOpen((v) => !v)}
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
        {/* A shell's output is a FILE the CLI never streams, so viewing it means
            tailing that file; an agent or workflow has a real transcript, so
            viewing it means the same drill-in the card offers. */}
        {shell ? (
          <TaskOutputView taskId={task.taskId} running={running} />
        ) : (
          <SubagentTranscriptView
            target={
              type === "local_workflow"
                ? { workflowRunId: record?.workflowRunId, taskId: task.taskId }
                : { taskId: task.taskId }
            }
            open={open}
            tick={running ? record?.progressTick : undefined}
          />
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
  if (tasks.length === 0) return null;

  return (
    <div className="tasks-strip">
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
        <ul className="tasks-list">
          {tasks.map((task) => (
            <TaskRow key={task.taskId} task={task} record={tasksById[task.taskId]} />
          ))}
        </ul>
      </Disclosure>
    </div>
  );
});
