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
    <Modal title={copy("supermux.harness.rewind.title")} onClose={onCancel}>
      <div className="rewind-form">
        <blockquote className="rewind-quote">
          {target.text.length > PREVIEW_CHARS
            ? `${target.text.slice(0, PREVIEW_CHARS)}…`
            : target.text}
        </blockquote>
        <p className="rewind-body">{copy("supermux.harness.rewind.body")}</p>

        <div className="rewind-files">
          {checking ? (
            <span className="rewind-checking">
              <Spinner size={11} />
              {copy("supermux.harness.rewind.checking")}
            </span>
          ) : degraded ? (
            <span className="rewind-degraded">
              <AlertTriangle size={12} />
              {copy("supermux.harness.rewind.unavailable")}
            </span>
          ) : (
            <label className="rewind-check">
              <input
                type="checkbox"
                checked={restoreFiles}
                disabled={fileCount === 0}
                onChange={(event) => setRestoreFiles(event.target.checked)}
              />
              <span className="rewind-check-label">
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
