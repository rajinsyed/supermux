import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, render } from "@testing-library/react";
import { createModel } from "../src/model/transcript";
import type { TranscriptModel } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { StatusStrip } from "../src/ui/status/StatusStrip";

afterEach(cleanup);

function mount(model: TranscriptModel, extra: { restarting?: boolean; cliUnavailable?: boolean } = {}) {
  return render(
    <CopyProvider dict={undefined}>
      <StatusStrip
        model={model}
        runPhase={model.runPhase}
        activity={model.activity}
        cliUnavailable={extra.cliUnavailable ?? false}
        restarting={extra.restarting}
        onRestart={() => {}}
      />
    </CopyProvider>
  );
}

function withQueue(count: number): TranscriptModel {
  const base = createModel();
  return {
    ...base,
    runPhase: "running",
    queued: Array.from({ length: count }, (_, i) => ({
      uuid: `q${i}`,
      text: `queued ${i}`,
      queuedAtMs: 1000 + i
    }))
  };
}

describe("the status strip never contradicts the queue strip", () => {
  test("a pane with messages waiting does not read Ready", () => {
    // This is the half of the queue bug a user actually sees: chips parked
    // under a green "Ready", which reads as "nothing is pending" while two
    // messages are.
    const { container } = mount(withQueue(2));
    const text = container.querySelector(".status-text")!.textContent;
    expect(text).not.toBe("Ready");
    expect(text).toBe("2 messages queued");
    expect(container.querySelector(".status-strip")!.className).toContain("is-busy");
  });

  test("one queued message inflects singular", () => {
    const { container } = mount(withQueue(1));
    expect(container.querySelector(".status-text")!.textContent).toBe("1 message queued");
  });

  test("an empty queue on an idle pane still reads Ready", () => {
    const { container } = mount(createModel());
    expect(container.querySelector(".status-text")!.textContent).toBe("Ready");
  });

  test("a live turn outranks the queue count", () => {
    // While Claude is actually working, what it is doing is the more useful
    // thing to say; the chips are visible directly above.
    const model = { ...withQueue(2) };
    model.activity = { ...model.activity, sessionState: "running" };
    const { container } = mount(model);
    expect(container.querySelector(".status-text")!.textContent).toBe("Claude is thinking…");
  });

  test("a restart says so rather than reading Ready or exited", () => {
    const model = { ...createModel(), runPhase: "exited" as const };
    const { container } = mount(model, { restarting: true });
    expect(container.querySelector(".status-text")!.textContent).toBe("Restarting Claude…");
  });

  test("a missing CLI still outranks everything", () => {
    const { container } = mount(withQueue(2), { cliUnavailable: true, restarting: true });
    expect(container.querySelector(".status-text")!.textContent).toBe("Claude Code CLI not found");
  });
});
