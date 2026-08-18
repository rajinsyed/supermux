import { useCallback, useEffect, useMemo, useState } from "react";
import type { TranscriptModel } from "../../model/types";
import type { CopyFn } from "../CopyContext";
import { activeView, createStack, popView, pushView, type HarnessView } from "./viewStack";

export interface ViewRouter {
  stack: HarnessView[];
  view: HarnessView;
  open(view: HarnessView): void;
  back(): void;
  labelFor(view: HarnessView): string;
}

/**
 * The pane's navigation.
 *
 * Escape is bound at the window because the reflex has to work wherever focus
 * happens to be — a dock row, the composer, a tool card the reader just
 * expanded. It defers to anything that owns Escape more locally (a modal, an
 * open popover, the composer's interrupt while a turn runs) by checking
 * `defaultPrevented`: those handlers call `preventDefault`, and a router that
 * popped the view anyway would close a dialog AND leave the agent view in one
 * press.
 */
export function useViewRouter(model: TranscriptModel, copy: CopyFn): ViewRouter {
  const [stack, setStack] = useState<HarnessView[]>(createStack);
  const view = activeView(stack);

  const open = useCallback((next: HarnessView) => {
    setStack((current) => pushView(current, next));
  }, []);

  const back = useCallback(() => {
    setStack((current) => popView(current));
  }, []);

  /**
   * A view whose subject has gone stops being a place you can be.
   *
   * `reset` and `truncateBeforeUserMessage` both drop threads and tasks the
   * stack may be pointing at, and a stack left holding them renders an agent
   * view with no agent — an empty screen with a back button, from which Escape
   * appears to do nothing until pressed as many times as the dead trail is
   * deep. Pruning is per-ENTRY rather than a full reset so an agent whose
   * PARENT workflow vanished still returns somewhere sensible.
   */
  useEffect(() => {
    setStack((current) => {
      const pruned = current.filter((entry) => {
        if (entry.kind === "agent") return model.agentThreads[entry.toolUseId] !== undefined;
        if (entry.kind === "workflow" || entry.kind === "shell") {
          return model.tasksById[entry.taskId] !== undefined;
        }
        return true;
      });
      if (pruned.length === current.length) return current;
      return pruned.length === 0 ? createStack() : pruned;
    });
  }, [model.agentThreads, model.tasksById]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      let popped = false;
      setStack((current) => {
        if (current.length <= 1) return current;
        popped = true;
        return popView(current);
      });
      // Only when it actually navigated: on the main view Escape still belongs
      // to the composer's interrupt, and swallowing it here would make Stop
      // stop working the moment the router mounted.
      if (popped) event.preventDefault();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  const labelFor = useCallback(
    (target: HarnessView): string => {
      switch (target.kind) {
        case "agent": {
          const thread = model.agentThreads[target.toolUseId];
          return thread?.description ?? copy("supermux.harness.dock.untitledAgent");
        }
        case "workflow": {
          const record = model.tasksById[target.taskId];
          return (
            record?.workflowName ??
            record?.workflow?.name ??
            copy("supermux.harness.dock.untitledWorkflow")
          );
        }
        case "shell": {
          const record = model.tasksById[target.taskId];
          return record?.description ?? copy("supermux.harness.dock.untitledShell");
        }
        default:
          return copy("supermux.harness.view.rootCrumb");
      }
    },
    [copy, model.agentThreads, model.tasksById]
  );

  return useMemo(
    () => ({ stack, view, open, back, labelFor }),
    [back, labelFor, open, stack, view]
  );
}
