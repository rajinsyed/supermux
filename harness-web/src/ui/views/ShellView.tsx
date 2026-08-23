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
  scrollRef,
  contentRef
}: {
  record: TaskRecord | undefined;
  scrollRef: RefObject<HTMLDivElement | null>;
  /**
   * A shell's output tail is the one view that grows without ANY frame arriving
   * — the native side polls a file and the text simply gets longer. Without the
   * content ref the scroll hook has nothing to observe here, so a tail that
   * outgrew the pane stopped following and, once the reader had scrolled, gave
   * them no way to tell they were no longer at the end.
   */
  contentRef?: RefObject<HTMLDivElement | null>;
}) {
  const copy = useCopy();

  if (!record) {
    return (
      <div className="harness-scroll transcript" ref={scrollRef}>
        <div className="transcript-inner" ref={contentRef}>
          <div className="drill-status">{copy("supermux.harness.agentView.unavailable")}</div>
        </div>
      </div>
    );
  }

  const running = !isTaskSettled(record.status);

  return (
    <div className="harness-scroll transcript shell-view" ref={scrollRef}>
      <div className="transcript-inner" ref={contentRef}>
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
