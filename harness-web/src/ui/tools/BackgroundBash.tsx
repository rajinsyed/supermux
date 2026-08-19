import { useState, type ReactNode } from "react";
import { getBridge } from "../../bridge";
import type { CopyKey } from "../../copyKeys";
import type { ToolBlock } from "../../model/types";
import { useCopy, type CopyFn } from "../CopyContext";
import { ChevronDown, ChevronRight, Stop } from "../Icons";
import { formatCompactDuration } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Spinner } from "../primitives/Spinner";
import { useDismissible } from "../primitives/useDismissible";
import { usePresentationState } from "../presentationState";
import { useFoldHold } from "../transcript/foldGuard";
import { TaskOutputView } from "./TaskOutput";

const STATUS_LABELS: Record<string, CopyKey> = {
  running: "supermux.harness.bash.statusRunning",
  pending: "supermux.harness.bash.statusRunning",
  completed: "supermux.harness.bash.statusCompleted",
  failed: "supermux.harness.bash.statusFailed",
  killed: "supermux.harness.bash.statusKilled",
  stopped: "supermux.harness.bash.statusKilled"
};

/** A Bash whose command is (or was) running outside the turn that started it. */
export function isBackgroundBash(block: ToolBlock): boolean {
  return block.subagent?.background === true && block.subagent.taskId !== undefined;
}

/**
 * The status a backgrounded Bash's own chrome should wear.
 *
 * Its `tool_result` returns instantly ("Command running in background…"), so
 * `block.status` says success while the command is still running — a green
 * check on a row whose own badge says "Still running". The card's border,
 * tint, and mark follow the TASK instead: running until the task settles, then
 * the task's real outcome. Two sources of truth on one row must not disagree.
 */
export function backgroundBashStatus(block: ToolBlock): ToolBlock["status"] {
  if (!isBackgroundBash(block)) return block.status;
  const status = block.subagent?.status;
  if (status === "completed") return "success";
  if (status === "failed") return "error";
  if (status === "killed" || status === "stopped") return "aborted";
  return "running";
}

/**
 * The head chips a backgrounded command carries. Kept apart from the strip so a
 * FOLDED card still says the command is in the background and what it is doing —
 * which is the state a user scrolling back is most often in.
 */
export function backgroundBashBadges(block: ToolBlock, copy: CopyFn): ReactNode[] {
  const info = block.subagent;
  if (!info?.background) return [];
  const badges: ReactNode[] = [
    <span key="bg" className="tool-badge is-quiet">
      {info.backgroundedByUser
        ? copy("supermux.harness.bash.backgroundedByUser")
        : copy("supermux.harness.bash.background")}
    </span>
  ];
  if (info.timedOutAfterMs !== undefined) {
    badges.push(
      <span key="timeout" className="tool-badge is-quiet tnum">
        {copy("supermux.harness.bash.autoBackgrounded", {
          duration: formatCompactDuration(info.timedOutAfterMs, copy)
        })}
      </span>
    );
  }
  const label = info.status ? STATUS_LABELS[info.status] : undefined;
  if (label) {
    const live = info.status === "running" || info.status === "pending";
    badges.push(
      <span
        key="status"
        className={`tool-badge ${live ? "is-live" : info.status === "failed" ? "is-error" : "is-quiet"}`}
      >
        {live ? <Spinner size={8} /> : null}
        {copy(label)}
      </span>
    );
  }
  return badges;
}

/**
 * The actions a Bash card offers below its output.
 *
 * Two distinct states share this row, and the difference matters:
 *  - a FOREGROUND command that is still running can be moved to the background
 *    (the CLI's ctrl+B), which is the only way to get the turn back without
 *    killing the command; and
 *  - a BACKGROUND command has no output in the transcript at all — the CLI
 *    streams none — so its output lives behind "Show output", tailing the task
 *    file, and it can be stopped from here as well as from the strip.
 */
export function BackgroundBashStrip({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const [openOutput, setOpenOutput] = usePresentationState(
    `block:${block.key}:background-output`,
    false
  );
  const [busy, setBusy] = useState<"move" | "stop" | undefined>(undefined);
  const [error, setError] = useState<CopyKey | undefined>(undefined);
  // Escape closes the tail, through the one contract all three inline drill-ins
  // now share, rather than each card re-implementing it on its own container.
  const scope = useDismissible(openOutput, () => setOpenOutput(false));
  // An open tail is the reader's place in this turn; the turn must not fold
  // itself away around it when the shell settles.
  useFoldHold(openOutput);

  const info = block.subagent;
  const background = info?.background === true;
  const taskId = info?.taskId;
  const status = info?.status;
  const taskRunning = status === "running" || status === "pending" || status === undefined;
  const toolRunning = block.status === "running" || block.status === "pending";

  const move = () => {
    setBusy("move");
    setError(undefined);
    getBridge()
      .backgroundTask({ toolUseId: block.toolUseId })
      .catch(() => setError("supermux.harness.bash.moveFailed"))
      .finally(() => setBusy(undefined));
  };

  const stop = () => {
    if (!taskId) return;
    setBusy("stop");
    setError(undefined);
    getBridge()
      .stopTask({ taskId })
      .catch(() => setError("supermux.harness.tasks.stopFailed"))
      .finally(() => setBusy(undefined));
  };

  /**
   * The task's closing word, when it is actually a word the card does not
   * already carry.
   *
   * The CLI's `task_notification.summary` for a shell is very often just the
   * command's own `description` verbatim — the same string already printed as
   * the card's subtitle two rows up — so a settled card read its description
   * twice, once styled as a subtitle and once as bare grey prose. Suppressed
   * when it matches anything the head already says; a summary that carries real
   * news ("exit 1: no such file") still gets its row.
   */
  const said = new Set(
    [
      info?.description,
      block.input.description,
      block.input.command,
      // The head's headline is the command's first LINE, so a summary equal to
      // that is a repeat too.
      typeof block.input.command === "string" ? block.input.command.split("\n")[0] : undefined
    ]
      .filter((value): value is string => typeof value === "string")
      .map((value) => value.trim())
  );
  const summary =
    info?.summary && !taskRunning && !said.has(info.summary.trim()) ? info.summary : undefined;

  // A foreground command that has already returned has nothing to move and
  // nothing to tail; the card is complete as it stands.
  if (!background && !toolRunning) return null;

  return (
    <div className="bash-bg-strip" ref={scope as React.RefObject<HTMLDivElement>}>
      <div className="bash-bg-actions">
        {!background && toolRunning ? (
          <button
            type="button"
            className="btn btn-quiet"
            onClick={move}
            disabled={busy !== undefined}
            // The tooltip explains what happens; the visible keycap chip
            // already carries the key, so repeating "Ctrl+B" here explained
            // nothing about the one affordance a terminal user has never seen.
            title={copy("supermux.harness.bash.moveToBackgroundHint")}
          >
            {busy === "move"
              ? copy("supermux.harness.bash.moving")
              : copy("supermux.harness.bash.moveToBackground")}
            <span className="btn-kbd">{copy("supermux.harness.bash.moveToBackgroundKey")}</span>
          </button>
        ) : null}
        {background && taskId ? (
          <>
            <button
              type="button"
              className="btn btn-quiet"
              onClick={() => setOpenOutput((v) => !v)}
              aria-expanded={openOutput}
            >
              {openOutput ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
              {openOutput
                ? copy("supermux.harness.bash.hideOutput")
                : copy("supermux.harness.bash.showOutput")}
            </button>
            {taskRunning ? (
              <button
                type="button"
                className="btn btn-quiet is-danger"
                onClick={stop}
                disabled={busy !== undefined}
              >
                <Stop size={10} />
                {busy === "stop"
                  ? copy("supermux.harness.tasks.stopping")
                  : copy("supermux.harness.bash.stop")}
              </button>
            ) : null}
          </>
        ) : null}
      </div>
      {error ? <div className="bash-bg-error">{copy(error)}</div> : null}
      {background && taskId ? (
        <Disclosure open={openOutput}>
          <TaskOutputView taskId={taskId} running={taskRunning} presented={openOutput} />
        </Disclosure>
      ) : null}
      {summary ? <div className="bash-bg-summary">{summary}</div> : null}
    </div>
  );
}
