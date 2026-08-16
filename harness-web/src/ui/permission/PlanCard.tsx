import { useEffect, useRef, useState } from "react";
import type { PendingPermission } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Map as MapIcon } from "../Icons";
import { CopyButton } from "../primitives/CopyButton";
import { Markdown } from "../primitives/Markdown";
import type { PermissionDecision } from "./PermissionCard";
import { setModeSuggestion } from "./permissionText";

export function PlanCard({
  pending,
  onDecide
}: {
  pending: PendingPermission;
  onDecide: (decision: PermissionDecision) => void;
}) {
  const copy = useCopy();
  const request = pending.request;
  const plan =
    (typeof request.input.plan === "string" ? request.input.plan : undefined) ??
    (typeof request.input.get_plan === "string" ? request.input.get_plan : "");
  const [expanded, setExpanded] = useState(plan.split("\n").length <= 24);
  const primary = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    primary.current?.focus();
  }, [pending.requestId]);

  return (
    <section className="plan-card" role="alertdialog" aria-live="assertive">
      <header className="plan-head">
        <span className="plan-icon">
          <MapIcon size={13} />
        </span>
        <div className="plan-title">
          <span className="plan-badge">{copy("supermux.harness.plan.badge")}</span>
          <h3>{request.title ?? copy("supermux.harness.plan.title")}</h3>
        </div>
        <CopyButton text={plan} label={copy("supermux.harness.plan.copy")} />
      </header>

      <div className={`plan-body${expanded ? "" : " is-clipped"}`}>
        <Markdown text={plan} />
      </div>
      {!expanded ? (
        <button type="button" className="plan-expand link-btn" onClick={() => setExpanded(true)}>
          {copy("supermux.harness.turn.showFullMessage")}
        </button>
      ) : null}

      <footer className="plan-actions">
        <button
          ref={primary}
          type="button"
          className="btn btn-primary"
          onClick={() =>
            onDecide({
              behavior: "allow",
              updatedInput: request.input,
              updatedPermissions: [setModeSuggestion(request, "acceptEdits")]
            })
          }
        >
          {copy("supermux.harness.plan.approveAuto")}
          <kbd>⏎</kbd>
        </button>
        <button
          type="button"
          className="btn btn-secondary"
          onClick={() =>
            onDecide({
              behavior: "allow",
              updatedInput: request.input,
              updatedPermissions: [setModeSuggestion(request, "default")]
            })
          }
        >
          {copy("supermux.harness.plan.approveManual")}
        </button>
        <span className="permission-spacer" />
        <button
          type="button"
          className="btn btn-ghost"
          onClick={() =>
            onDecide({
              behavior: "deny",
              message: copy("supermux.harness.plan.keepPlanningMessage")
            })
          }
        >
          {copy("supermux.harness.plan.keepPlanning")}
          <kbd>Esc</kbd>
        </button>
      </footer>
    </section>
  );
}
