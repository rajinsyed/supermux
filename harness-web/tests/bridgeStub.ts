import type { HarnessBridge } from "../src/bridge";

/**
 * The round-3 bridge methods, stubbed inert.
 *
 * The suites that build their own `HarnessBridge` are testing send ordering,
 * restarts, and rewinds — none of which touch tasks. Spreading one shared stub
 * keeps them satisfying the interface without five copies of the same four
 * no-ops, and means adding a bridge method later fails to compile in ONE place.
 */
export const taskBridgeStub: Pick<
  HarnessBridge,
  "stopTask" | "backgroundTask" | "loadSubagentTranscript" | "readTaskOutput" | "readImage"
> = {
  async stopTask() {},
  async backgroundTask() {
    return { backgrounded: false };
  },
  async loadSubagentTranscript() {
    return { events: [], truncated: false, missing: true };
  },
  async readTaskOutput() {
    return { text: "", truncated: false, missing: true };
  },
  async readImage() {
    throw new Error("unused bridge method");
  }
};
