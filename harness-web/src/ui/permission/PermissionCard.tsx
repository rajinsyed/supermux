import { useCallback, useEffect, useId, useRef, useState } from "react";
import type { PendingPermission } from "../../model/types";
import type { PermissionSuggestion, StructuredPatchHunk } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { ArrowLeft, Shield, ShieldCheck, XCircle } from "../Icons";
import { languageForPath, shortenPath } from "../format";
import { CodeBlock } from "../primitives/CodeBlock";
import { DiffView } from "../primitives/DiffView";
import { toolFamily } from "../tools/toolMeta";
import { alwaysAllowOffer, permissionHeadline } from "./permissionText";
import { useCardKeys } from "./useCardKeys";

export interface PermissionDecision {
  behavior: "allow" | "deny";
  updatedInput?: unknown;
  updatedPermissions?: PermissionSuggestion[];
  message?: string;
  interrupt?: boolean;
}

export function PermissionCard({
  pending,
  queueCount,
  onDecide
}: {
  pending: PendingPermission;
  queueCount: number;
  onDecide: (decision: PermissionDecision) => void;
}) {
  const copy = useCopy();
  const request = pending.request;
  const [showDeny, setShowDeny] = useState(false);
  const [reason, setReason] = useState("");
  const cardRef = useRef<HTMLElement>(null);
  const allowRef = useRef<HTMLButtonElement>(null);
  const denyRef = useRef<HTMLButtonElement>(null);
  const headingId = useId();
  const always = alwaysAllowOffer(request, copy);
  const sublabel = always
    ? `${copy("supermux.harness.permission.allowAlwaysRule", { rule: always.rule })} · ${always.destination}`
    : "";

  useEffect(() => {
    setShowDeny(false);
    setReason("");
  }, [pending.requestId]);

  useEffect(() => {
    if (!showDeny) allowRef.current?.focus();
  }, [pending.requestId, showDeny]);

  const closeDeny = useCallback(() => {
    setShowDeny(false);
    setReason("");
  }, []);

  // Only the top-level action row answers the request from the keyboard. Once
  // the deny sub-state is open, Escape backs out of it instead — a mis-click on
  // Deny must not be a one-way door into the reason prompt.
  const onKey = useCallback(
    (event: KeyboardEvent) => {
      if (showDeny) {
        if (event.key === "Escape") {
          event.preventDefault();
          closeDeny();
        }
        return;
      }
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        onDecide({ behavior: "allow", updatedInput: request.input });
      } else if ((event.key === "a" || event.key === "A") && always) {
        event.preventDefault();
        onDecide({
          behavior: "allow",
          updatedInput: request.input,
          updatedPermissions: [always.suggestion]
        });
      } else if (event.key === "Escape") {
        event.preventDefault();
        setShowDeny(true);
      }
    },
    [always, closeDeny, onDecide, request.input, showDeny]
  );

  useCardKeys(cardRef, onKey);

  return (
    <section
      className="permission-card"
      role="alertdialog"
      aria-live="assertive"
      aria-labelledby={headingId}
      aria-describedby={`${headingId}-desc`}
      ref={cardRef}
    >
      {/* An alertdialog announces its name and description; the headline alone
          says which command, not that a decision is being demanded. */}
      <p id={`${headingId}-desc`} className="sr-only">
        {copy("supermux.harness.a11y.permissionAlert")}
      </p>
      <header className="permission-head">
        <span className="permission-icon">
          <Shield size={13} />
        </span>
        <div className="permission-title">
          <span className="permission-badge">{copy("supermux.harness.permission.title")}</span>
          <h3 id={headingId}>{permissionHeadline(request)}</h3>
          {request.decision_reason ? (
            <p className="permission-reason">{request.decision_reason}</p>
          ) : null}
        </div>
        {queueCount > 0 ? (
          <span className="permission-queue tnum">
            {copy("supermux.harness.permission.moreWaiting", { count: queueCount })}
          </span>
        ) : null}
      </header>

      <PermissionPreview pending={pending} />

      {request.blocked_path ? (
        <div className="permission-path mono">
          <span className="permission-path-label">
            {copy("supermux.harness.permission.blockedPath")}
          </span>
          {shortenPath(request.blocked_path, 4)}
        </div>
      ) : null}

      {showDeny ? (
        <div className="permission-deny-row">
          <button
            type="button"
            className="btn btn-ghost btn-icon-only"
            onClick={closeDeny}
            title={copy("supermux.harness.permission.denyBack")}
            aria-label={copy("supermux.harness.permission.denyBack")}
          >
            <ArrowLeft size={12} />
          </button>
          <input
            className="permission-reason-input"
            placeholder={copy("supermux.harness.permission.denyReason")}
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape") {
                event.preventDefault();
                closeDeny();
              } else if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                denyRef.current?.click();
              }
            }}
            autoFocus
          />
          <button
            ref={denyRef}
            type="button"
            className="btn btn-danger"
            onClick={() =>
              onDecide({
                behavior: "deny",
                message: reason.trim() || copy("supermux.harness.permission.deny")
              })
            }
          >
            {copy("supermux.harness.permission.deny")}
            <kbd>⏎</kbd>
          </button>
          <button
            type="button"
            className="btn btn-ghost"
            onClick={() =>
              onDecide({
                behavior: "deny",
                message: reason.trim() || copy("supermux.harness.permission.deny"),
                interrupt: true
              })
            }
          >
            {copy("supermux.harness.permission.denyAndStop")}
          </button>
        </div>
      ) : (
        <footer className="permission-actions">
          <button
            ref={allowRef}
            type="button"
            className="btn btn-primary"
            onClick={() => onDecide({ behavior: "allow", updatedInput: request.input })}
          >
            {copy("supermux.harness.permission.allowOnce")}
            <kbd>⏎</kbd>
          </button>
          {always ? (
            <button
              type="button"
              className="btn btn-secondary btn-stacked"
              onClick={() =>
                onDecide({
                  behavior: "allow",
                  updatedInput: request.input,
                  updatedPermissions: [always.suggestion]
                })
              }
            >
              <span className="btn-line">
                <ShieldCheck size={12} />
                {copy("supermux.harness.permission.allowAlways")}
                <kbd>A</kbd>
              </span>
              {/* The rule is the whole decision: a glob that grants one
                  directory and one that grants the entire tree differ only in
                  the tail that a single ellipsised line throws away. So the
                  sublabel wraps — the card is the transcript's tail element and
                  has the vertical room — and still carries the full string as a
                  tooltip for the pathological case. */}
              <span className="btn-sub" title={sublabel}>
                {sublabel}
              </span>
            </button>
          ) : null}
          <span className="permission-spacer" />
          <button type="button" className="btn btn-ghost" onClick={() => setShowDeny(true)}>
            <XCircle size={12} />
            {copy("supermux.harness.permission.deny")}
            <kbd>Esc</kbd>
          </button>
        </footer>
      )}
    </section>
  );
}

function PermissionPreview({ pending }: { pending: PendingPermission }) {
  const request = pending.request;
  const family = toolFamily(request.tool_name);
  const input = request.input;

  if (family === "bash" && typeof input.command === "string") {
    return (
      <div className="permission-preview">
        <CodeBlock code={input.command} language="bash" dense maxLines={12} />
        {typeof input.description === "string" ? (
          <p className="permission-desc">{input.description}</p>
        ) : null}
      </div>
    );
  }

  if (family === "edit" || family === "write") {
    const path = typeof input.file_path === "string" ? input.file_path : undefined;
    const language = languageForPath(path);
    const hunks = synthesizeHunks(input);
    return (
      <div className="permission-preview">
        {path ? <div className="permission-file mono">{shortenPath(path, 4)}</div> : null}
        {hunks.length > 0 ? (
          <DiffView hunks={hunks} language={language} maxRows={16} />
        ) : typeof input.content === "string" ? (
          <CodeBlock code={input.content} language={language} maxLines={14} />
        ) : null}
      </div>
    );
  }

  const json = JSON.stringify(input, null, 2);
  if (json === "{}") return null;
  return (
    <div className="permission-preview">
      <CodeBlock code={json} language="json" dense maxLines={12} />
    </div>
  );
}

function synthesizeHunks(input: Record<string, unknown>): StructuredPatchHunk[] {
  const oldText = typeof input.old_string === "string" ? input.old_string : undefined;
  const newText = typeof input.new_string === "string" ? input.new_string : undefined;
  if (oldText === undefined && newText === undefined) return [];
  const lines: string[] = [];
  if (oldText !== undefined) for (const line of oldText.split("\n")) lines.push(`-${line}`);
  if (newText !== undefined) for (const line of newText.split("\n")) lines.push(`+${line}`);
  return [
    {
      oldStart: 1,
      oldLines: oldText ? oldText.split("\n").length : 0,
      newStart: 1,
      newLines: newText ? newText.split("\n").length : 0,
      lines
    }
  ];
}
