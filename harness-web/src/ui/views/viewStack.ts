/**
 * Which surface the pane is showing, and how it got there.
 *
 * The CLI lets you walk into an agent, into a workflow, into one of that
 * workflow's agents, and back out again — so "where am I" is a STACK, not a
 * single value. Escape pops one level, which is only correct if the route
 * remembers that an agent opened from a workflow belongs to that workflow and
 * not to the main chat.
 *
 * Pure on purpose: the whole navigation contract is testable without mounting
 * anything, and the hook below is a thin `useState` over these functions.
 */
export type HarnessView =
  | { kind: "main" }
  | { kind: "agent"; toolUseId: string }
  | { kind: "workflow"; taskId: string }
  | { kind: "shell"; taskId: string };

export const MAIN_VIEW: HarnessView = { kind: "main" };

export function viewKey(view: HarnessView): string {
  switch (view.kind) {
    case "agent":
      return `agent:${view.toolUseId}`;
    case "workflow":
      return `workflow:${view.taskId}`;
    case "shell":
      return `shell:${view.taskId}`;
    default:
      return "main";
  }
}

export function sameView(a: HarnessView, b: HarnessView): boolean {
  return viewKey(a) === viewKey(b);
}

/** The stack always has a floor: the main chat is where the pane lives. */
export function createStack(): HarnessView[] {
  return [MAIN_VIEW];
}

export function activeView(stack: HarnessView[]): HarnessView {
  return stack.length > 0 ? stack[stack.length - 1] : MAIN_VIEW;
}

/**
 * Walk INTO a view.
 *
 * Re-opening what is already on top is a no-op rather than a second copy: the
 * dock row for the agent you are already reading must not need two Escapes to
 * leave. Opening `main` is not a push but a reset — the breadcrumb's root, the
 * dock's first row, and the Escape-to-main reflex all mean the same thing, and a
 * stack that grew a second `main` on top of an agent would strand that agent
 * underneath it.
 */
export function pushView(stack: HarnessView[], view: HarnessView): HarnessView[] {
  if (view.kind === "main") return createStack();
  const current = activeView(stack);
  if (sameView(current, view)) return stack;
  // Re-entering a view already on the trail returns to it rather than stacking a
  // duplicate: workflow → agent → (its parent workflow) is a step BACK, and two
  // identical frames would make Escape appear to do nothing the first time.
  const existing = stack.findIndex((entry) => sameView(entry, view));
  if (existing >= 0) return stack.slice(0, existing + 1);
  return stack.concat(view);
}

/** Escape. The floor never pops: main is where the stack bottoms out. */
export function popView(stack: HarnessView[]): HarnessView[] {
  if (stack.length <= 1) return stack;
  return stack.slice(0, -1);
}

/**
 * The view a stack entry returns to, for the back affordance's label. Undefined
 * on the main view, which has nowhere to go.
 */
export function parentView(stack: HarnessView[]): HarnessView | undefined {
  return stack.length > 1 ? stack[stack.length - 2] : undefined;
}
