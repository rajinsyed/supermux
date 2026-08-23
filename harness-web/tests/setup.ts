import { GlobalRegistrator } from "@happy-dom/global-registrator";

GlobalRegistrator.register({ width: 1200, height: 800, url: "http://localhost/" });

// happy-dom has no layout engine, so `matchMedia` is undefined and rAF fires
// asynchronously. The Disclosure animation is opt-out under reduced motion,
// which is the deterministic branch tests want.
if (typeof window.matchMedia !== "function") {
  window.matchMedia = ((query: string) => ({
    matches: query.includes("prefers-reduced-motion"),
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false
  })) as typeof window.matchMedia;
}

declare global {
  // eslint-disable-next-line no-var
  var IS_REACT_ACT_ENVIRONMENT: boolean;
}

globalThis.IS_REACT_ACT_ENVIRONMENT = true;
