import {
  createContext,
  useContext,
  useLayoutEffect,
  useSyncExternalStore,
  type ReactNode
} from "react";
import type { HarnessStore } from "../model/store";

const PresentationVisibilityContext = createContext(true);

export function PresentationVisibilityProvider({
  store,
  children
}: {
  store: HarnessStore;
  children: ReactNode;
}) {
  const visible = useSyncExternalStore(
    store.subscribePresentation,
    store.getPresentationVisible,
    store.getPresentationVisible
  );

  useLayoutEffect(() => {
    const root = document.documentElement;
    const value = visible ? "visible" : "hidden";
    root.dataset.supermuxPresentation = value;
    return () => {
      if (root.dataset.supermuxPresentation === value) {
        delete root.dataset.supermuxPresentation;
      }
    };
  }, [visible]);

  return (
    <PresentationVisibilityContext.Provider value={visible}>
      {children}
    </PresentationVisibilityContext.Provider>
  );
}

export function usePresentationVisible(): boolean {
  return useContext(PresentationVisibilityContext);
}
