import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
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

/**
 * The strip is the EXCEPTION line now.
 *
 * It used to narrate every ordinary state of a turn — thinking, running a tool,
 * starting, queued, waiting for approval — and every one of those was already
 * on screen somewhere the reader was looking: the composer's Stop button IS the
 * running state, the queue chips ARE the queue, the permission card IS the
 * approval request. Worse, the row appeared and disappeared as a turn advanced,
 * so the composer and the whole bottom bar under it moved 17px each way several
 * times a turn.
 *
 * What is left is the set of states with no other surface at all: the CLI is
 * missing, the process died, or it is being restarted.
 */
describe("the strip says nothing the pane already says", () => {
  test("a running turn raises no strip — the composer's Stop is that state", () => {
    const model = withQueue(0);
    model.activity = { ...model.activity, sessionState: "running" };
    const { container } = mount(model);
    expect(container.querySelector(".status-strip")).toBeNull();
  });

  test("queued messages raise no strip — the chips in the composer are the queue", () => {
    const { container } = mount(withQueue(2));
    expect(container.querySelector(".status-strip")).toBeNull();
  });

  test("a pending permission raises no strip — the card is the request", () => {
    const base = createModel();
    const model = {
      ...base,
      runPhase: "running" as const,
      pending: [{ id: "p1", toolName: "Bash", input: {}, requestedAtMs: 1000 }]
    } as unknown as TranscriptModel;
    const { container } = mount(model);
    expect(container.querySelector(".status-strip")).toBeNull();
  });

  test("an idle pane with nothing to say renders no strip at all", () => {
    // "Ready" is retired: a permanent status line restating the absence of news
    // was chrome.
    const { container } = mount(createModel());
    expect(container.querySelector(".status-strip")).toBeNull();
  });
});

describe("the strip still speaks for the states with no other surface", () => {
  test("a missing CLI outranks everything", () => {
    const { container } = mount(withQueue(2), { cliUnavailable: true, restarting: true });
    expect(container.querySelector(".status-text")!.textContent).toBe("Claude Code CLI not found");
    expect(container.querySelector(".status-strip")!.className).toContain("is-error");
  });

  test("a restart says so rather than reading exited", () => {
    const model = { ...createModel(), runPhase: "exited" as const };
    const { container } = mount(model, { restarting: true });
    expect(container.querySelector(".status-text")!.textContent).toBe("Restarting Claude…");
  });

  test("an exit carries the one control that can undo it", () => {
    // Restart lives nowhere else in the dock, which is the whole reason this
    // state survived the cull.
    let restarted = 0;
    const model = { ...createModel(), runPhase: "exited" as const };
    render(
      <CopyProvider dict={undefined}>
        <StatusStrip
          model={model}
          runPhase={model.runPhase}
          activity={model.activity}
          cliUnavailable={false}
          onRestart={() => {
            restarted += 1;
          }}
        />
      </CopyProvider>
    );
    screen.getByText("Restart").click();
    expect(restarted).toBe(1);
  });

  test("the process's own exit message outranks the generic one", () => {
    const model = { ...createModel(), runPhase: "exited" as const, exitError: "spawn ENOENT" };
    const { container } = mount(model);
    expect(container.querySelector(".status-text")!.textContent).toBe("spawn ENOENT");
  });
});
