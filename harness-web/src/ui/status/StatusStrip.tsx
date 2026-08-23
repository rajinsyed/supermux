import type { ActivityState, RunPhase, TranscriptModel } from "../../model/types";
import { useCopy } from "../CopyContext";
import { AlertTriangle, Refresh } from "../Icons";

/**
 * The exception line, above the composer.
 *
 * It used to narrate the ordinary: "Claude is thinking…", "Running Bash",
 * "Starting Claude…", "2 messages queued", "Waiting for your approval". Every
 * one of those was already on screen — the composer's Stop button IS the
 * running state, the queue chips ARE the queue, the permission card IS the
 * approval request — so the strip was a second, slower copy of the pane's own
 * news, and it appeared and disappeared under the composer as a turn advanced,
 * shifting the whole dock by 17px each way.
 *
 * What survives is the half that has no other surface: the pane cannot run at
 * all (no CLI on disk), or its process died and the only way back is a button
 * that lives here. A restart is the same family — the composer is disabled and
 * nothing else says why — and it is the one transient state kept, because it
 * ends by itself in a second or two.
 */
export function StatusStrip({
  runPhase,
  model,
  cliUnavailable,
  restarting,
  onRestart
}: {
  model: TranscriptModel;
  runPhase: RunPhase;
  /** Retained for the caller's shape; no ordinary activity is narrated here. */
  activity?: ActivityState;
  /** No CLI on disk: the pane cannot start, so the strip must not read "Ready". */
  cliUnavailable: boolean;
  /** The old process is down and the new one is not up yet. */
  restarting?: boolean;
  onRestart: () => void;
}) {
  const copy = useCopy();

  if (cliUnavailable) {
    return (
      <Strip tone="error">
        <AlertTriangle size={12} className="status-glyph" />
        <span className="status-text">{copy("supermux.harness.status.noCli")}</span>
      </Strip>
    );
  }

  if (restarting) {
    return (
      <Strip tone="busy">
        <Refresh size={12} className="status-glyph is-spinning" />
        <span className="status-text">{copy("supermux.harness.status.restarting")}</span>
      </Strip>
    );
  }

  if (runPhase === "exited") {
    if (model.turns.length > 0) return null;
    return (
      <Strip tone="error">
        <AlertTriangle size={12} className="status-glyph" />
        <span className="status-text">
          {model.exitError ??
            copy(
              model.startFailed
                ? "supermux.harness.error.startFailed"
                : "supermux.harness.status.exited"
            )}
        </span>
        <button type="button" className="status-action" onClick={onRestart}>
          <Refresh size={11} />
          {copy("supermux.harness.status.restart")}
        </button>
      </Strip>
    );
  }

  return null;
}

function Strip({ tone, children }: { tone: string; children: React.ReactNode }) {
  return (
    <div className={`status-strip is-${tone}`} role="status" aria-live="polite">
      {children}
    </div>
  );
}
