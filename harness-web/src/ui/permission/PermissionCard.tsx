import { useEffect, useRef, useState } from "react";
import type { PendingPermission } from "../../model/types";
import type { PermissionSuggestion, StructuredPatchHunk } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { Shield, ShieldCheck, XCircle } from "../Icons";
import { languageForPath, shortenPath } from "../format";
import { CodeBlock } from "../primitives/CodeBlock";
import { DiffView } from "../primitives/DiffView";
import { toolFamily } from "../tools/toolMeta";
import { alwaysAllowOffer, permissionHeadline } from "./permissionText";

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
  const allowRef = useRef<HTMLButtonElement>(null);
  const always = alwaysAllowOffer(request, copy);

  useEffect(() => {
    allowRef.current?.focus();
  }, [pending.requestId]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (target && (target.tagName === "TEXTAREA" || target.tagName === "INPUT")) return;
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
        onDecide({ behavior: "deny", message: copy("supermux.harness.permission.deny") });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [always, onDecide, request.input, copy]);

  return (
    <section className="permission-card" role="alertdialog" aria-live="assertive">
      <header className="permission-head">
        <span className="permission-icon">
          <Shield size={13} />
        </span>
        <div className="permission-title">
          <span className="permission-badge">{copy("supermux.harness.permission.title")}</span>
          <h3>{permissionHeadline(request)}</h3>
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
          <input
            className="permission-reason-input"
            placeholder={copy("supermux.harness.permission.denyReason")}
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            autoFocus
          />
          <button
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
              <span className="btn-sub mono">{always.rule}</span>
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
