import { useEffect, useRef, useState } from "react";
import type { BinarySetting } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { Modal } from "../primitives/Modal";

/**
 * The pane resolves `claude` off PATH, which is wrong for anyone whose real
 * entrypoint is a wrapper — a proxy launcher, a version-manager shim, a script.
 * They had no way to say so short of editing the app's defaults by hand.
 *
 * Validation is the native side's job (exists / executable / not a directory):
 * it is the only party that can stat the path, and a web-side guess would
 * disagree with it. This dialog shows what came back.
 */
export function BinaryDialog({
  onClose,
  load,
  save
}: {
  onClose(): void;
  load(): Promise<BinarySetting>;
  save(path: string | undefined): Promise<BinarySetting>;
}) {
  const copy = useCopy();
  const [setting, setSetting] = useState<BinarySetting | undefined>(undefined);
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const field = useRef<HTMLInputElement>(null);

  useEffect(() => {
    let live = true;
    load()
      .then((next) => {
        if (!live) return;
        setSetting(next);
        setValue(next.overridePath ?? "");
      })
      .catch((reason: unknown) => {
        if (live) setError(reason instanceof Error ? reason.message : undefined);
      });
    return () => {
      live = false;
    };
  }, [load]);

  useEffect(() => {
    field.current?.focus();
  }, []);

  const commit = (next: string | undefined) => {
    setBusy(true);
    setError(undefined);
    setSaved(false);
    save(next)
      .then((result) => {
        setSetting(result);
        setValue(result.overridePath ?? "");
        setSaved(true);
      })
      .catch((reason: unknown) => {
        // The whole point of the field is that the path may be wrong; saying so
        // in place beats closing the dialog on a silent no-op.
        setError(reason instanceof Error ? reason.message : copy("supermux.harness.error.generic"));
      })
      .finally(() => setBusy(false));
  };

  return (
    <Modal title={copy("supermux.harness.binary.title")} onClose={onClose}>
      <div className="binary-form">
        <div className="binary-resolved">
          <span className="binary-label">{copy("supermux.harness.binary.resolved")}</span>
          <span className="binary-path mono" title={setting?.resolvedPath}>
            {setting?.resolvedPath ?? copy("supermux.harness.binary.resolvedNone")}
          </span>
          {setting?.version ? (
            <span className="binary-version tnum">
              {copy("supermux.harness.binary.version", { version: setting.version })}
            </span>
          ) : null}
        </div>

        <label className="binary-field">
          <span className="binary-label">{copy("supermux.harness.binary.overrideLabel")}</span>
          <input
            ref={field}
            className="binary-input mono"
            type="text"
            value={value}
            spellCheck={false}
            autoComplete="off"
            placeholder={copy("supermux.harness.binary.overridePlaceholder")}
            onChange={(event) => {
              setValue(event.target.value);
              setSaved(false);
              setError(undefined);
            }}
            onKeyDown={(event) => {
              if (event.key !== "Enter") return;
              event.preventDefault();
              commit(value.trim() || undefined);
            }}
          />
        </label>
        <p className="binary-help">{copy("supermux.harness.binary.help")}</p>

        {error ? (
          <p className="binary-error" role="alert">
            {error}
          </p>
        ) : (
          <p className="binary-note">{copy("supermux.harness.binary.appliesNextStart")}</p>
        )}

        <div className="binary-actions">
          {saved && !error ? (
            <span className="binary-saved">{copy("supermux.harness.binary.saved")}</span>
          ) : null}
          <span className="binary-actions-spacer" />
          <button
            type="button"
            className="btn btn-ghost"
            disabled={busy || (!setting?.overridePath && value.trim().length === 0)}
            onClick={() => {
              setValue("");
              commit(undefined);
            }}
          >
            {copy("supermux.harness.binary.clear")}
          </button>
          <button type="button" className="btn btn-secondary" onClick={onClose}>
            {copy("supermux.harness.binary.cancel")}
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled={busy}
            onClick={() => commit(value.trim() || undefined)}
          >
            {copy("supermux.harness.binary.save")}
          </button>
        </div>
      </div>
    </Modal>
  );
}
