import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { taskBridgeStub } from "./bridgeStub";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { HarnessBridge } from "../src/bridge";
import { copyDefaults } from "../src/copyKeys";
import { REWIND_UUIDS, rewindHistory } from "../src/dev/fixtures/rewind";
import { HarnessStore } from "../src/model/store";
import type { RewindResult } from "../src/protocol/types";
import { App } from "../src/ui/App";
import { CopyProvider } from "../src/ui/CopyContext";
import { ExitedState, stderrExcerpt } from "../src/ui/empty/EmptyStates";
import { defaultDarkTheme } from "../src/ui/theme";

afterEach(cleanup);
beforeEach(() => {
  delete window.supermuxHarnessMock;
});

const noop = async () => {};

function makeBridge(reply: RewindResult): HarnessBridge {
  return {
    async context() {
      return {
        panelId: "p",
        theme: defaultDarkTheme,
        copy: { ...copyDefaults },
        cliStatus: { available: true, version: "2.1.233" },
        restore: { sessionId: "rewind-session-7712" }
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory() {
      return { events: rewindHistory, truncated: false };
    },
    async start() {
      return { runId: "run-1" };
    },
    async restart() {
      return { runId: "run-2" };
    },
    openSessionInNewPane: noop,
    async send() {
      return { sent: true };
    },
    interrupt: noop,
    cancelQueued: noop,
    stop: noop,
    setModel: noop,
    setPermissionMode: noop,
    respondPermission: noop,
    renameSession: noop,
    async getContextUsage() {
      return { totalTokens: 0, maxTokens: 200000, percentage: 0 };
    },
    async fileSuggestions() {
      return { paths: [] };
    },
    async pickFiles() {
      return { images: [], paths: [] };
    },
    openFile: noop,
    copyText: noop,
    async saveFile() {
      return { saved: false };
    },
    notify: noop,
    saveDraft: noop,
    async getBinarySetting() {
      return {};
    },
    async setBinaryPath() {
      return {};
    },
    async rewindPreview() {
      return { canRewind: true, filesChanged: ["/a/one.swift"], insertions: 3, deletions: 1 };
    },
    async rewind() {
      return reply;
    },
    ...taskBridgeStub
  };
}

async function flush(ms = 20) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

/** Open the rewind dialog on the third message and confirm it. */
async function rewindThirdMessage(restoreFiles: boolean) {
  const store = new HarnessStore();
  render(<App store={store} />);
  await flush();

  const bubbles = document.querySelectorAll(".user-msg");
  expect(bubbles.length).toBeGreaterThan(2);
  await act(async () => {
    fireEvent.click(bubbles[2].querySelector(".user-msg-rewind")!);
  });
  await flush();

  const box = screen.queryByRole("checkbox") as HTMLInputElement | null;
  if (box && box.checked !== restoreFiles) fireEvent.click(box);
  await act(async () => {
    fireEvent.click(screen.getByText("Rewind & edit"));
  });
  await flush();
  return store;
}

/**
 * A rewind has two halves that fail independently: the conversation restart,
 * and `rewind_files`. The controller used to catch every file-restore failure
 * into a stderr line and return plain success, so the pane told the user their
 * working tree had been restored to a point it had never been moved to — and
 * the stderr line explaining why was collected into a field nothing rendered.
 * The reply now reports the halves separately, and the note follows it.
 */
describe("the rewind note reports the half that leaves no trace", () => {
  test("a restore that failed is not reported as a plain success", async () => {
    window.supermuxHarnessMock = makeBridge({
      runId: "run-3",
      filesRestored: false,
      reason: "rewind_files: no checkpoint recorded for this message"
    });
    await rewindThirdMessage(true);

    const note = document.querySelector(".rewind-note")!;
    expect(note.textContent).toContain("Conversation rewound; files could not be restored.");
    // And it LOOKS like the warning it is: the same accent as a plain success
    // understates the one fact the user has to act on.
    expect(note.className).toContain("is-degraded");
    expect(note.getAttribute("role")).toBe("alert");
  });

  test("the reason travels with it, so the user is not left guessing", async () => {
    window.supermuxHarnessMock = makeBridge({
      runId: "run-3",
      filesRestored: false,
      reason: "rewind_files: no checkpoint recorded for this message"
    });
    await rewindThirdMessage(true);
    expect(document.querySelector(".rewind-note")!.textContent).toContain(
      "no checkpoint recorded for this message"
    );
  });

  test("a rewind that fully SUCCEEDED says nothing at all", async () => {
    // The success note went with the completion chips. It restated something
    // the user had just watched happen — the transcript truncated and their
    // message went back in the composer — and then had to be closed by hand.
    window.supermuxHarnessMock = makeBridge({ runId: "run-3", filesRestored: true });
    const store = await rewindThirdMessage(true);
    expect(document.querySelector(".rewind-note")).toBeNull();
    // The rewind itself plainly happened; only the chip is gone.
    expect(store.getSnapshot().turns.map((turn) => turn.userUuid)).toEqual([
      REWIND_UUIDS.first,
      REWIND_UUIDS.second
    ]);
  });

  test("a conversation-only rewind is a success, so it says nothing either", async () => {
    // filesRestored is false here too — nothing was ASKED for. Reading that as a
    // failure would put a warning on every deliberate conversation-only rewind.
    window.supermuxHarnessMock = makeBridge({ runId: "run-3", filesRestored: false });
    await rewindThirdMessage(false);
    expect(document.querySelector(".rewind-note")).toBeNull();
  });

  test("the degraded half does not undo the conversation half", async () => {
    // The transcript still truncates and the composer is still refilled: the
    // conversation WAS rewound, and pretending otherwise would be the opposite
    // lie to the one being fixed.
    window.supermuxHarnessMock = makeBridge({
      runId: "run-3",
      filesRestored: false,
      reason: "no checkpoint"
    });
    const store = await rewindThirdMessage(true);
    expect(store.getSnapshot().turns.map((turn) => turn.userUuid)).toEqual([
      REWIND_UUIDS.first,
      REWIND_UUIDS.second
    ]);
  });
});

/**
 * `stderrTail` was collected on every run and rendered nowhere — 40 lines of the
 * CLI's own diagnostics, kept for nothing. It belongs exactly where a user asks
 * "why did that die": `runExited.error` is often only a signal number, while the
 * line above it in stderr names the missing module or the bad flag.
 */
describe("the exited card shows what the process actually said", () => {
  const mount = (node: React.ReactElement) =>
    render(<CopyProvider dict={undefined}>{node}</CopyProvider>);

  test("the last stderr lines are rendered beside the exit reason", () => {
    const { container } = mount(
      <ExitedState
        error="claude exited unexpectedly (signal 9)"
        stderrTail={["Error: Cannot find module 'node:sqlite'", "  at Module._resolve"]}
        onRestart={() => {}}
      />
    );
    const shown = container.querySelector(".exited-stderr")!.textContent ?? "";
    expect(shown).toContain("Cannot find module 'node:sqlite'");
    expect(container.querySelector(".exited-body")!.textContent).toBe(
      "claude exited unexpectedly (signal 9)"
    );
  });

  test("no stderr means no empty block", () => {
    const { container } = mount(<ExitedState error="exited" stderrTail={[]} onRestart={() => {}} />);
    expect(container.querySelector(".exited-stderr")).toBeNull();
  });

  test("blank and whitespace-only lines are not shown as output", () => {
    expect(stderrExcerpt(["", "   ", "real failure", "\n"])).toEqual(["real failure"]);
  });

  test("only the tail is shown, so a chatty process cannot fill the pane", () => {
    const many = Array.from({ length: 40 }, (_, i) => `line ${i}`);
    const excerpt = stderrExcerpt(many);
    expect(excerpt.length).toBe(4);
    expect(excerpt[excerpt.length - 1]).toBe("line 39");
  });
});
