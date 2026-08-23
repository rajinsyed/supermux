import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { REWIND_UUIDS, rewindHistory } from "../src/dev/fixtures/rewind";
import { resumeHistory } from "../src/dev/fixtures/resume";
import { applyLocalAction, createIndex, createModel, replayLines } from "../src/model/transcript";
import type { TranscriptModel } from "../src/model/types";
import type { RewindPreview } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { RewindDialog } from "../src/ui/transcript/RewindDialog";
import { TurnView } from "../src/ui/transcript/TurnView";

afterEach(cleanup);

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

/**
 * A rewind is addressed by the uuid of the user message it targets, so a
 * transcript that drops uuids has no rewindable messages at all — and history
 * replay is exactly where they were most at risk of being dropped.
 */
describe("user-message uuids survive both paths into the model", () => {
  test("a locally-sent message keeps the uuid the send stamped", () => {
    const index = createIndex();
    const model = applyLocalAction(
      createModel(),
      index,
      { kind: "localSend", uuid: "local-1", text: "hello", atMs: 1000 },
      1000
    );
    expect(model.turns[0].userUuid).toBe("local-1");
    expect(model.turns[0].userText).toBe("hello");
  });

  test("a replayed history message keeps the uuid from its JSONL record", () => {
    const model = replayLines(rewindHistory);
    expect(model.turns.map((turn) => turn.userUuid)).toEqual([
      REWIND_UUIDS.first,
      REWIND_UUIDS.second,
      REWIND_UUIDS.third,
      REWIND_UUIDS.fourth
    ]);
  });

  test("the shipped resume fixture is rewindable too, not only the new one", () => {
    const model = replayLines(resumeHistory);
    expect(model.turns.length).toBeGreaterThan(0);
    for (const turn of model.turns) {
      expect(typeof turn.userUuid).toBe("string");
      expect(turn.userUuid!.length).toBeGreaterThan(0);
    }
  });
});

describe("truncateBeforeUserMessage matches --resume-session-at", () => {
  const model = (): TranscriptModel => replayLines(rewindHistory);

  function truncate(from: TranscriptModel, uuid: string): TranscriptModel {
    return applyLocalAction(from, createIndex(), { kind: "truncateBeforeUserMessage", uuid }, 1);
  }

  test("the target turn and everything after it is dropped", () => {
    const next = truncate(model(), REWIND_UUIDS.third);
    expect(next.turns.map((t) => t.userUuid)).toEqual([REWIND_UUIDS.first, REWIND_UUIDS.second]);
  });

  test("rewinding to the first message leaves an empty transcript", () => {
    const next = truncate(model(), REWIND_UUIDS.first);
    expect(next.turns).toEqual([]);
  });

  test("rewinding to the last message keeps everything before it", () => {
    const next = truncate(model(), REWIND_UUIDS.fourth);
    expect(next.turns.length).toBe(3);
  });

  test("an unknown uuid changes nothing rather than clearing the pane", () => {
    const before = model();
    const next = truncate(before, "not-a-message");
    expect(next).toBe(before);
  });

  test("state that described the dropped turns goes with them", () => {
    // A permission prompt for a tool call that no longer exists cannot be
    // answered, and a queued message was typed against a conversation that is
    // being rewritten.
    const seeded: TranscriptModel = {
      ...model(),
      pending: [
        {
          requestId: "req-1",
          kind: "permission",
          request: { subtype: "can_use_tool", tool_name: "Bash", input: {} } as never,
          receivedAtMs: 1
        }
      ],
      queued: [{ uuid: "q1", text: "queued", queuedAtMs: 1 }],
      todos: [{ content: "step", status: "pending" }],
      activity: { sessionState: "running", status: "requesting", thinkingTokens: 40 }
    };
    const next = truncate(seeded, REWIND_UUIDS.third);
    expect(next.pending).toEqual([]);
    expect(next.queued).toEqual([]);
    expect(next.todos).toEqual([]);
    expect(next.activity.sessionState).toBe("idle");
    expect(next.activity.status).toBeNull();
  });
});

describe("every user message offers a rewind", () => {
  test("a turn with a uuid renders the affordance", () => {
    const turn = replayLines(rewindHistory).turns[2];
    const { container } = mount(<TurnView turn={turn} isLast={false} onRewind={() => {}} />);
    expect(container.querySelector(".user-msg-rewind")).not.toBeNull();
  });

  test("clicking it reports the message's own uuid", () => {
    const turn = replayLines(rewindHistory).turns[2];
    const seen: string[] = [];
    mount(<TurnView turn={turn} isLast={false} onRewind={(uuid) => seen.push(uuid)} />);
    fireEvent.click(screen.getByLabelText("Rewind"));
    expect(seen).toEqual([REWIND_UUIDS.third]);
  });

  test("a turn with no uuid shows no button rather than a dead one", () => {
    // Nothing for the CLI to address: a rewind control that cannot rewind is
    // worse than no control.
    const turn = { ...replayLines(rewindHistory).turns[2], userUuid: undefined };
    const { container } = mount(<TurnView turn={turn} isLast={false} onRewind={() => {}} />);
    expect(container.querySelector(".user-msg-rewind")).toBeNull();
    // Copy is unaffected — the two share the hover row.
    expect(container.querySelector(".copy-btn")).not.toBeNull();
  });
});

const PREVIEW: RewindPreview = {
  canRewind: true,
  filesChanged: ["/a/one.swift", "/a/two.swift"],
  insertions: 12,
  deletions: 4
};

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

describe("the rewind dialog states what it is about to do", () => {
  const target = { uuid: REWIND_UUIDS.third, text: "Rename the resume helper", resumeAtUuid: REWIND_UUIDS.second };

  test("the dry run's file count and diff are shown before confirming", async () => {
    mount(
      <RewindDialog
        target={target}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={async () => PREVIEW}
      />
    );
    await settle();
    expect(screen.getByText("2 files · +12 −4")).toBeDefined();
  });

  test("the message being rewound to is quoted, not summarised", async () => {
    const { container } = mount(
      <RewindDialog
        target={target}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={async () => PREVIEW}
      />
    );
    await settle();
    expect(container.querySelector(".rewind-quote")!.textContent).toBe("Rename the resume helper");
  });

  test("confirming passes the checkbox state through", async () => {
    const decisions: boolean[] = [];
    mount(
      <RewindDialog
        target={target}
        onCancel={() => {}}
        onConfirm={(restore) => decisions.push(restore)}
        loadPreview={async () => PREVIEW}
      />
    );
    await settle();
    fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByText("Rewind & edit"));
    expect(decisions).toEqual([false]);
  });

  test("a session with no checkpoints degrades to conversation-only, with the reason", async () => {
    mount(
      <RewindDialog
        target={target}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={async () => ({ canRewind: false, filesChanged: [], insertions: 0, deletions: 0 })}
      />
    );
    await settle();
    // No checkbox to arm, and the note says why rather than leaving a disabled
    // control with no explanation.
    expect(screen.queryByRole("checkbox")).toBeNull();
    expect(
      screen.getByText(
        "This session has no file checkpoints, so only the conversation can be rewound."
      )
    ).toBeDefined();
  });

  test("the degraded path still confirms, and never claims it restored files", async () => {
    const decisions: boolean[] = [];
    mount(
      <RewindDialog
        target={target}
        onCancel={() => {}}
        onConfirm={(restore) => decisions.push(restore)}
        loadPreview={async () => ({ canRewind: false, filesChanged: [], insertions: 0, deletions: 0 })}
      />
    );
    await settle();
    fireEvent.click(screen.getByText("Rewind & edit"));
    expect(decisions).toEqual([false]);
  });

  test("a preview that has nothing to restore does not arm the checkbox", async () => {
    mount(
      <RewindDialog
        target={target}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={async () => ({ canRewind: true, filesChanged: [], insertions: 0, deletions: 0 })}
      />
    );
    await settle();
    const box = screen.getByRole("checkbox") as HTMLInputElement;
    expect(box.checked).toBe(false);
    expect(box.disabled).toBe(true);
    expect(screen.getByText("No file changes to restore")).toBeDefined();
  });

  test("confirm is held back until the dry run answers", () => {
    // Confirming mid-flight would send `restoreFiles` from a default nobody
    // has seen the consequences of.
    mount(
      <RewindDialog
        target={target}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={() => new Promise<RewindPreview>(() => {})}
      />
    );
    expect((screen.getByText("Rewind & edit") as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText("Checking what changed…")).toBeDefined();
  });
});
