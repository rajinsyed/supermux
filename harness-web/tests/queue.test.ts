import { describe, expect, test } from "bun:test";
import { applyLine, applyLocalAction, createIndex, createModel } from "../src/model/transcript";
import type { LocalAction, TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";

const index = () => createIndex();

function send(
  model: TranscriptModel,
  ix: ReturnType<typeof createIndex>,
  uuid: string,
  text: string,
  atMs: number
): TranscriptModel {
  return applyLocalAction(model, ix, { kind: "localSend", uuid, text, atMs }, atMs);
}

function act(
  model: TranscriptModel,
  ix: ReturnType<typeof createIndex>,
  action: LocalAction
): TranscriptModel {
  return applyLocalAction(model, ix, action, Date.now());
}

function line(model: TranscriptModel, ix: ReturnType<typeof createIndex>, l: ProtocolLine) {
  return applyLine(model, ix, l, Date.now());
}

// Every frame carries a distinct uuid: the reducer dedups on it, so reusing
// one would silently drop the second turn's result and pass for the wrong
// reason.
let frame = 0;
function resultLine(): ProtocolLine {
  frame += 1;
  return {
    type: "result",
    subtype: "success",
    is_error: false,
    result: "done",
    uuid: `res-${frame}`
  } as ProtocolLine;
}

function assistantLine(): ProtocolLine {
  frame += 1;
  return {
    type: "assistant",
    message: { id: `m${frame}`, role: "assistant", content: [{ type: "text", text: "hi" }] },
    uuid: `asst-${frame}`
  } as ProtocolLine;
}

/**
 * The reported symptom: chips sat under a "Ready" status while a message typed
 * AFTER them opened its own turn and got answered first. Both halves are here —
 * the ordering, and the status that made it look sanctioned.
 */
describe("a queue drains in the order it was filled", () => {
  test("a send typed into the post-result gap does not jump the queue", () => {
    const ix = index();
    let model = createModel();

    // Turn one is live; two follow-ups queue behind it.
    model = send(model, ix, "u1", "first", 1000);
    expect(model.turns.length).toBe(1);
    model = send(model, ix, "u2", "second", 2000);
    model = send(model, ix, "u3", "third", 3000);
    expect(model.queued.map((q) => q.text)).toEqual(["second", "third"]);

    // The result settles the turn and clears sessionState to idle. This is the
    // exact window the bug lived in: no turn open, state idle, queue non-empty.
    model = line(model, ix, resultLine());
    expect(model.activity.sessionState).toBe("idle");
    expect(model.turns.every((t) => t.state !== "streaming")).toBe(true);
    expect(model.queued.length).toBe(2);

    // A message typed right here used to skip the queue and open turn two,
    // rendering and answering ahead of "second" and "third".
    model = send(model, ix, "u4", "fourth", 4000);

    expect(model.turns.length).toBe(1);
    expect(model.queued.map((q) => q.text)).toEqual(["second", "third", "fourth"]);
  });

  test("the queue then promotes strictly first-in-first-out", () => {
    const ix = index();
    let model = createModel();
    model = send(model, ix, "u1", "first", 1000);
    model = send(model, ix, "u2", "second", 2000);
    model = send(model, ix, "u3", "third", 3000);
    model = line(model, ix, resultLine());
    model = send(model, ix, "u4", "fourth", 4000);

    // Each new turn's first frame promotes queued[0] — three more turns, in
    // the order the user typed them.
    for (let i = 0; i < 3; i += 1) {
      model = line(model, ix, assistantLine());
      model = line(model, ix, resultLine());
    }

    expect(model.turns.map((t) => t.userText)).toEqual(["first", "second", "third", "fourth"]);
    expect(model.queued).toEqual([]);
  });

  test("an empty queue on an idle pane still sends immediately", () => {
    // The fix must not turn every send into a queued one: with nothing waiting
    // and nothing running, a message opens its turn at once.
    const ix = index();
    let model = createModel();
    model = send(model, ix, "u1", "only", 1000);
    expect(model.queued).toEqual([]);
    expect(model.turns.length).toBe(1);
    expect(model.turns[0].userText).toBe("only");
  });

  test("cancelling the last chip reopens the immediate path", () => {
    const ix = index();
    let model = createModel();
    model = send(model, ix, "u1", "first", 1000);
    model = send(model, ix, "u2", "second", 2000);
    model = line(model, ix, resultLine());
    model = act(model, ix, { kind: "cancelQueued", uuid: "u2" });
    expect(model.queued).toEqual([]);

    model = send(model, ix, "u3", "third", 3000);
    expect(model.turns.map((t) => t.userText)).toEqual(["first", "third"]);
  });

  test("a lifecycle 'started' mid-turn interjects the chip instead of banking it", () => {
    // The real CLI does not hold a queued message for the next turn: its
    // command_lifecycle frame flips to "started" at the running turn's next
    // step and the SAME turn's remaining output answers it (probed against
    // claude 2.1.235 — "also say BANANA" queued mid-count made the running
    // turn's final message say BANANA). Before this fix the chip stayed in
    // `queued`, so after the result the CLI's summary leg promoted it into a
    // second turn: the message rendered twice, below the answer it already
    // had, and Claude looked psychic ("how did you know i was gonna ask?").
    const ix = index();
    let model = createModel();
    model = send(model, ix, "u1", "count to five", 1000);
    model = send(model, ix, "u2", "also say BANANA", 2000);
    expect(model.queued.map((q) => q.text)).toEqual(["also say BANANA"]);

    model = line(model, ix, {
      type: "command_lifecycle",
      command_uuid: "u2",
      state: "started",
      uuid: "lc-1"
    } as ProtocolLine);

    // The chip moved INTO the running turn as an interjected user bubble.
    expect(model.queued).toEqual([]);
    expect(model.turns.length).toBe(1);
    const interjected = model.turns[0].blocks.find(
      (b) => b.kind === "userText" && b.interjection
    );
    expect(interjected).toBeDefined();
    expect((interjected as { text: string }).text).toBe("also say BANANA");

    // The result settles ONE turn, and the next output leg opens no ghost turn
    // for the already-consumed message.
    model = line(model, ix, resultLine());
    model = line(model, ix, assistantLine());
    expect(model.turns.map((t) => t.userText)).toEqual(["count to five"]);
  });

  test("a lifecycle 'started' with no open turn leaves the chip queued", () => {
    // The race the guard exists for: the lifecycle frame lands after the
    // result already closed the turn. The CLI is opening a fresh turn for the
    // message, so the normal promotion path must keep working.
    const ix = index();
    let model = createModel();
    model = send(model, ix, "u1", "first", 1000);
    model = send(model, ix, "u2", "second", 2000);
    model = line(model, ix, resultLine());
    model = line(model, ix, {
      type: "command_lifecycle",
      command_uuid: "u2",
      state: "started",
      uuid: "lc-2"
    } as ProtocolLine);
    expect(model.queued.map((q) => q.text)).toEqual(["second"]);

    model = line(model, ix, assistantLine());
    expect(model.turns.map((t) => t.userText)).toEqual(["first", "second"]);
  });

  test("a replayed mid_turn user line files inside the open turn", () => {
    // The on-disk transcript has NO user record for a consumed queued message
    // — only a `queued_command` attachment, which the native mapper forwards
    // as a `mid_turn` user line. It must land inside the turn it interjected
    // into, not open a turn of its own.
    const ix = index();
    let model = createModel();
    model = send(model, ix, "u1", "count to five", 1000);
    model = line(model, ix, {
      type: "user",
      mid_turn: true,
      uuid: "u2",
      message: { role: "user", content: "also say BANANA" }
    } as ProtocolLine);

    expect(model.turns.length).toBe(1);
    const interjected = model.turns[0].blocks.find(
      (b) => b.kind === "userText" && b.interjection
    );
    expect(interjected).toBeDefined();

    // With no turn open it degrades to an ordinary user turn — typed text is
    // never dropped.
    model = line(model, ix, resultLine());
    model = line(model, ix, {
      type: "user",
      mid_turn: true,
      uuid: "u3",
      message: { role: "user", content: "orphaned" }
    } as ProtocolLine);
    expect(model.turns.map((t) => t.userText)).toEqual(["count to five", "orphaned"]);
  });

  test("interrupt-with-cancel empties the queue rather than stranding it", () => {
    // The CLI drops queued messages on a cancelling interrupt. If the chips
    // survived locally they would block every later send forever, because a
    // non-empty queue is now itself a busy signal.
    const ix = index();
    let model = createModel();
    model = send(model, ix, "u1", "first", 1000);
    model = send(model, ix, "u2", "second", 2000);
    model = act(model, ix, { kind: "clearQueued" });
    expect(model.queued).toEqual([]);

    model = line(model, ix, resultLine());
    model = send(model, ix, "u3", "third", 3000);
    expect(model.turns.map((t) => t.userText)).toEqual(["first", "third"]);
  });
});
