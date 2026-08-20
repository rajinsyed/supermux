import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { harnessStore } from "./model/store";
import { App } from "./ui/App";
import { PresentationVisibilityProvider } from "./ui/presentationVisibility";
import "./styles/index.css";

const container = document.getElementById("root");
if (container) {
  createRoot(container).render(
    <StrictMode>
      <PresentationVisibilityProvider store={harnessStore}>
        <App store={harnessStore} />
      </PresentationVisibilityProvider>
    </StrictMode>
  );
}
