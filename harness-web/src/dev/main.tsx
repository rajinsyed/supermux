import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { harnessStore } from "../model/store";
import { App } from "../ui/App";
import { installMockBridge } from "./mockBridge";
import "../styles/index.css";

installMockBridge(harnessStore);

const container = document.getElementById("root");
if (container) {
  createRoot(container).render(
    <StrictMode>
      <App store={harnessStore} />
    </StrictMode>
  );
}
