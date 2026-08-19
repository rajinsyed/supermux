import { useEffect, useState } from "react";
import type { RewindPreview } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { AlertTriangle } from "../Icons";
import { Modal } from "../primitives/Modal";
import { Spinner } from "../primitives/Spinner";

export interface RewindTarget {
  uuid: string;
  text: string;
  /** The previous user message's uuid; absent when rewinding to message one. */
  resumeAtUuid?: string;
}

const PREVIEW_CHARS = 400;

/**
 * Rewind is destructive twice over — it drops conversation AND rewrites files
 * on disk — so the dry run happens before the user commits, and the file half is
 * a separate, separately-refusable checkbox. Sessions recorded without SDK file
 * checkpointing answer `canRewind: false`; that degrades to conversation-only
 * with the reason stated, rather than failing at confirm time.
 *
 * Round 6 rebuilds the LAYOUT around that fact, because the round-5 dialog did
 * not state it. It was a quote, a loose sentence, a bordered well, and a
 * checkbox — four unrelated blocks in which the reader had to work out for
 * themselves that a rewind does two separable things. It is now literally a list
 * of those two effects, in the kit's own selectable-row shape:
 *
 *   · the CONVERSATION effect, which always happens and says so with a quiet
 *     "Always" rather than a disabled checkbox nobody can act on;
 *   · the FILES effect, which is the checkbox — checked, unchecked, unavailable
 *     (no checkpoints), or empty (nothing changed) — and carries the dry run's
 *     own numbers on its own row.
 *
 * Nothing about what is submitted changes: `onConfirm(armed)` still receives the
 * single boolean, and `armed` is still restoreFiles AND NOT degraded.
 */
export function RewindDialog({
  target,
  onCancel,
  onConfirm,
  loadPreview
}: {
  target: RewindTarget;
  onCancel(): void;
  onConfirm(restoreFiles: boolean): void;
  loadPreview(uuid: string): Promise<RewindPreview>;
}) {
  const copy = useCopy();
  const [preview, setPreview] = useState<RewindPreview | undefined>(undefined);
  const [failed, setFailed] = useState(false);
  const [restoreFiles, setRestoreFiles] = useState(true);

  useEffect(() => {
    let live = true;
    loadPreview(target.uuid)
      .then((next) => {
        if (!live) return;
        setPreview(next);
        // Never silently arm a destructive default the CLI just said it cannot
        // honour, and never arm one with nothing to restore.
        setRestoreFiles(next.canRewind && next.filesChanged.length > 0);
      })
      .catch(() => {
        if (!live) return;
        setFailed(true);
        setRestoreFiles(false);
      });
    return () => {
      live = false;
    };
  }, [loadPreview, target.uuid]);

  const checking = preview === undefined && !failed;
  const degraded = failed || (preview !== undefined && !preview.canRewind);
  const fileCount = preview?.filesChanged.length ?? 0;
  /** Files will actually be overwritten: the one irreversible half of a rewind. */
  const armed = restoreFiles && !degraded;

  return (
    <Modal title={copy("supermux.harness.rewind.title")} size="compact" onClose={onCancel}>
      <div className="rewind-form">
        {/* The quote is what the whole dialog is ABOUT, so it is labelled rather
            than left as an unattributed block of the user's own words sitting
            above a sentence about something else. */}
        <div className="rewind-target">
          <span className="rewind-target-label">
            {copy("supermux.harness.rewind.quoteLabel")}
          </span>
          <blockquote className="rewind-quote">
            {target.text.length > PREVIEW_CHARS
              ? `${target.text.slice(0, PREVIEW_CHARS)}…`
              : target.text}
          </blockquote>
        </div>

        <div className="rewind-effects">
          {/* Effect one: not a choice, so not drawn as one. */}
          <div className="rewind-effect is-fixed">
            <span className="rewind-effect-mark" aria-hidden="true" />
            <span className="rewind-effect-text">
              <span className="rewind-effect-title">
                {copy("supermux.harness.rewind.conversationTitle")}
              </span>
              <span className="rewind-body">{copy("supermux.harness.rewind.body")}</span>
            </span>
            <span className="rewind-stat">{copy("supermux.harness.rewind.always")}</span>
          </div>

          {/* Effect two: the one the user can refuse — or that the session
              cannot offer at all. */}
          {checking ? (
            <div className="rewind-effect is-checking">
              <Spinner size={11} />
              <span className="rewind-checking">
                {copy("supermux.harness.rewind.checking")}
              </span>
            </div>
          ) : degraded ? (
            <div className="rewind-effect is-degraded">
              <AlertTriangle size={12} />
              <span className="rewind-degraded">
                {copy("supermux.harness.rewind.unavailable")}
              </span>
            </div>
          ) : (
            <label
              className={`rewind-effect rewind-check${restoreFiles ? " is-on" : ""}${
                fileCount === 0 ? " is-empty" : ""
              }`}
            >
              <input
                type="checkbox"
                checked={restoreFiles}
                disabled={fileCount === 0}
                onChange={(event) => setRestoreFiles(event.target.checked)}
              />
              <span className="rewind-effect-text">
                <span className="rewind-check-label rewind-effect-title">
                  {copy("supermux.harness.rewind.restoreFiles")}
                </span>
                <span className="rewind-stat tnum">
                  {fileCount === 0
                    ? copy("supermux.harness.rewind.noFiles")
                    : copy(
                        fileCount === 1
                          ? "supermux.harness.rewind.filesChangedOne"
                          : "supermux.harness.rewind.filesChanged",
                        {
                          count: fileCount,
                          added: preview?.insertions ?? 0,
                          removed: preview?.deletions ?? 0
                        }
                      )}
                </span>
              </span>
            </label>
          )}
        </div>

        <div className="rewind-actions">
          <button type="button" className="btn btn-secondary" onClick={onCancel}>
            {copy("supermux.harness.rewind.cancel")}
          </button>
          {/* Dropping conversation is reversible — the session is still on disk
              and can be resumed. Overwriting files on disk is not, and the same
              accent-coloured button for both understates the second by drawing
              it exactly like every ordinary confirm in the pane. The weight
              tracks what is ARMED, not merely what is possible, so a
              conversation-only rewind keeps the ordinary primary. */}
          <button
            type="button"
            className={`btn ${armed ? "btn-danger" : "btn-primary"}`}
            disabled={checking}
            onClick={() => onConfirm(armed)}
          >
            {copy("supermux.harness.rewind.confirm")}
          </button>
        </div>
      </div>
    </Modal>
  );
}
