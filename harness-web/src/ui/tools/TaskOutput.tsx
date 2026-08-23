import { useEffect, useRef, useState } from "react";
import { getBridge } from "../../bridge";
import { useCopy } from "../CopyContext";
import { AnsiOutput } from "../primitives/AnsiOutput";
import { Spinner } from "../primitives/Spinner";
import { usePresentationVisible } from "../presentationVisibility";

/**
 * How often an open output view re-reads the file while the task still runs.
 *
 * The CLI streams NO shell output frames — the text only ever exists in the
 * task's output file — so a live tail has to poll. 1.2s is roughly what the
 * CLI's own detail view refreshes at, it costs one local read per open view,
 * and it stops the moment the task settles or the view closes.
 */
const POLL_MS = 1200;

type Phase = "loading" | "ready" | "missing" | "failed";

interface TaskOutputViewProps {
  taskId: string;
  /** Poll while true; a settled task is read exactly once. */
  running: boolean;
  className?: string;
  /** False while an animating disclosure is mounted but no longer visible. */
  presented?: boolean;
  /** Focused-test seam; production retains the documented 1.2 second cadence. */
  pollIntervalMs?: number;
}

/**
 * A task id is the state identity, not just an effect dependency. Keying the
 * polling body makes loading state switch in the same render and prevents a
 * completion from the previous task from ever painting into the next one.
 */
export function TaskOutputView(props: TaskOutputViewProps) {
  return <TaskOutputPoller key={props.taskId} {...props} />;
}

function TaskOutputPoller({
  taskId,
  running,
  className,
  presented = true,
  pollIntervalMs = POLL_MS
}: TaskOutputViewProps) {
  const copy = useCopy();
  const presentationVisible = usePresentationVisible();
  const [phase, setPhase] = useState<Phase>("loading");
  const [text, setText] = useState("");
  const [truncated, setTruncated] = useState(false);
  const alive = useRef(true);

  useEffect(() => {
    if (!presented || !presentationVisible) return;
    alive.current = true;
    let timer = 0;
    let cancelled = false;

    const schedule = () => {
      if (running && !cancelled && alive.current) {
        timer = window.setTimeout(read, pollIntervalMs);
      }
    };
    const read = () => {
      getBridge()
        .readTaskOutput({ taskId })
        .then((result) => {
          if (cancelled || !alive.current) return;
          setTruncated(result.truncated === true);
          if (result.missing) {
            setPhase("missing");
          } else {
            setText(result.text ?? "");
            setPhase("ready");
          }
          schedule();
        })
        .catch(() => {
          if (cancelled || !alive.current) return;
          // Keep the last successful text and retry: output files can be between
          // writes or briefly unavailable while the producer rotates them.
          setPhase((previous) => (previous === "ready" ? previous : "failed"));
          schedule();
        });
    };
    read();

    return () => {
      cancelled = true;
      alive.current = false;
      if (timer) window.clearTimeout(timer);
    };
  }, [pollIntervalMs, presentationVisible, presented, running, taskId]);

  return (
    <div className={className ?? "task-output"}>
      <div className="task-output-head">
        <span className="task-output-title">{copy("supermux.harness.tasks.outputTitle")}</span>
        {running ? (
          <span className="task-output-live">
            <Spinner size={9} />
            {copy("supermux.harness.tasks.outputLive")}
          </span>
        ) : null}
        {truncated ? (
          <span className="task-output-note">{copy("supermux.harness.tasks.outputTruncated")}</span>
        ) : null}
      </div>
      {phase === "loading" ? (
        <div className="drill-status">
          <Spinner size={12} />
          {copy("supermux.harness.tasks.outputLoading")}
        </div>
      ) : phase === "missing" ? (
        <div className="drill-status">{copy("supermux.harness.tasks.outputMissing")}</div>
      ) : phase === "failed" ? (
        <div className="drill-status is-error">{copy("supermux.harness.tasks.outputFailed")}</div>
      ) : text.trim().length === 0 ? (
        <div className="drill-status">{copy("supermux.harness.tasks.outputEmpty")}</div>
      ) : (
        <AnsiOutput
          text={text}
          maxLines={18}
          stateKey={`task:${taskId}:output`}
          streaming={running}
        />
      )}
    </div>
  );
}
