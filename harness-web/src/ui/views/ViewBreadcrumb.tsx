import { useCopy } from "../CopyContext";
import { ArrowLeft, ChevronRight } from "../Icons";
import type { HarnessView } from "./viewStack";

/**
 * Where you are, and one press back.
 *
 * The trail is the STACK, not a computed path: an agent reached from a workflow
 * reads "Claude › alpha-beta-demo › merger", and Escape retraces exactly those
 * steps. Deriving it from the thread tree instead would show the agent's
 * PARENTAGE, which is a different fact and would make the back button disagree
 * with the crumb beside it.
 */
export function ViewBreadcrumb({
  stack,
  labelFor,
  onBack,
  onOpen
}: {
  stack: HarnessView[];
  labelFor(view: HarnessView): string;
  onBack(): void;
  onOpen(view: HarnessView): void;
}) {
  const copy = useCopy();
  if (stack.length <= 1) return null;
  const parent = stack[stack.length - 2];

  return (
    <div className="view-crumbs">
      <button
        type="button"
        className="btn btn-quiet view-back"
        onClick={onBack}
        title={copy("supermux.harness.view.backTo", { label: labelFor(parent) })}
        aria-label={copy("supermux.harness.view.backTo", { label: labelFor(parent) })}
      >
        <ArrowLeft size={12} />
        {copy("supermux.harness.view.back")}
      </button>
      <nav className="view-crumb-trail" aria-label={copy("supermux.harness.view.rootCrumb")}>
        {stack.map((view, index) => {
          const last = index === stack.length - 1;
          return (
            <span key={`${index}:${labelFor(view)}`} className="view-crumb">
              {index > 0 ? <ChevronRight size={9} className="view-crumb-sep" /> : null}
              {last ? (
                <span className="view-crumb-current" aria-current="page">
                  {labelFor(view)}
                </span>
              ) : (
                <button type="button" className="link-btn" onClick={() => onOpen(view)}>
                  {labelFor(view)}
                </button>
              )}
            </span>
          );
        })}
      </nav>
    </div>
  );
}
