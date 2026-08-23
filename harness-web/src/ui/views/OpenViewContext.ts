import { createContext } from "react";
import type { HarnessView } from "./viewStack";

/**
 * How anything deep in the transcript asks the router to change view.
 *
 * Threaded through context rather than props because the callers are leaves —
 * an agent row nested three tool cards down, a workflow row inside a folded
 * turn — and passing a navigation callback through every intermediate renderer
 * would put a router prop on components that have nothing to do with routing.
 *
 * The default is a no-op so a component rendered outside the router (a test
 * mounting one card, the export path) still renders rather than throwing on a
 * click it was never going to service.
 */
export const OpenViewContext = createContext<(view: HarnessView) => void>(() => undefined);
