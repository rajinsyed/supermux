import { useCallback, useEffect, useRef, useState } from "react";
import type { PendingPermission } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Download, Map as MapIcon } from "../Icons";
import { CopyButton } from "../primitives/CopyButton";
import { Markdown } from "../primitives/Markdown";
import { savePlanMarkdown } from "./savePlan";
import type { PermissionDecision } from "./PermissionCard";
import { setModeSuggestion } from "./permissionText";
import { useCardKeys } from "./useCardKeys";

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
  const cardRef = useRef<HTMLElement>(null);
  const primary = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    primary.current?.focus();
  }, [pending.requestId]);

  const approve = useCallback(
    (mode: "acceptEdits" | "default") => {
      onDecide({
        behavior: "allow",
        updatedInput: request.input,
        updatedPermissions: [setModeSuggestion(request, mode)]
      });
    },
    [onDecide, request]
  );

  const keepPlanning = useCallback(() => {
    onDecide({ behavior: "deny", message: copy("supermux.harness.plan.keepPlanningMessage") });
  }, [copy, onDecide]);

  // The card prints ⏎ and Esc on its buttons, so both must work from anywhere in
  // the pane — not only while the browser happens to have the primary focused.
  const onKey = useCallback(
    (event: KeyboardEvent) => {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        approve("acceptEdits");
      } else if (event.key === "Escape") {
        event.preventDefault();
        keepPlanning();
      }
    },
    [approve, keepPlanning]
  );

  useCardKeys(cardRef, onKey);

  return (
    <section className="plan-card" role="alertdialog" aria-live="assertive" ref={cardRef}>
      <header className="plan-head">
        <span className="plan-icon">
          <MapIcon size={13} />
        </span>
        <div className="plan-title">
          <span className="plan-badge">{copy("supermux.harness.plan.badge")}</span>
          <h3>{request.title ?? copy("supermux.harness.plan.title")}</h3>
        </div>
        <CopyButton text={plan} label={copy("supermux.harness.plan.copy")} />
        <button
          type="button"
          className="icon-btn"
          onClick={() => void savePlanMarkdown(plan, request.title)}
          title={copy("supermux.harness.plan.download")}
          aria-label={copy("supermux.harness.plan.download")}
        >
          <Download size={12} />
        </button>
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
          onClick={() => approve("acceptEdits")}
        >
          {copy("supermux.harness.plan.approveAuto")}
          <kbd>⏎</kbd>
        </button>
        <button type="button" className="btn btn-secondary" onClick={() => approve("default")}>
          {copy("supermux.harness.plan.approveManual")}
        </button>
        <span className="permission-spacer" />
        <button type="button" className="btn btn-ghost" onClick={keepPlanning}>
          {copy("supermux.harness.plan.keepPlanning")}
          <kbd>Esc</kbd>
        </button>
      </footer>
    </section>
  );
}
