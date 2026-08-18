import type { RefObject } from "react";
import { isTaskSettled } from "../../model/tasks";
import type { TaskRecord } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Terminal } from "../Icons";
import { Elapsed } from "../primitives/Elapsed";
import { TaskOutputView } from "../tools/TaskOutput";

/**
 * A background shell, as a full view.
 *
 * Its output tail is the whole of it: the CLI streams nothing for a shell, the
 * bytes accumulate in a file, and the native side tails that file on demand.
 * The round-3 popover on a strip row showed exactly this content in a box the
 * size of four lines; giving it the pane is the only change, and it is the one
 * that makes it readable.
 */
export function ShellView({
  record,
  scrollRef
}: {
  record: TaskRecord | undefined;
  scrollRef: RefObject<HTMLDivElement | null>;
}) {
  const copy = useCopy();

  if (!record) {
    return (
      <div className="harness-scroll transcript" ref={scrollRef}>
        <div className="transcript-inner">
          <div className="drill-status">{copy("supermux.harness.agentView.unavailable")}</div>
        </div>
      </div>
    );
  }

  const running = !isTaskSettled(record.status);

  return (
    <div className="harness-scroll transcript shell-view" ref={scrollRef}>
      <div className="transcript-inner">
        <div className="shell-view-head">
          <span className="shell-view-icon">
            <Terminal size={13} />
          </span>
          <span className="shell-view-name">
            {record.description ?? copy("supermux.harness.dock.untitledShell")}
          </span>
          {running ? (
            <Elapsed className="shell-view-elapsed tnum" startedAtMs={record.startedAtMs} />
          ) : null}
        </div>
        <TaskOutputView taskId={record.taskId} running={running} />
      </div>
    </div>
  );
}
