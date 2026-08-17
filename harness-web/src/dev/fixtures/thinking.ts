import type { ProtocolLine } from "../../protocol/types";
import {
  assistantThinking,
  blockStart,
  blockStop,
  initLine,
  initializeResponse,
  messageStart,
  resultLine,
  sessionState,
  statusLine,
  streamText,
  streamThinking,
  uid,
  userLine
} from "./build";

const MSG = "msg_thinking_0001";
const MSG_REDACTED = "msg_thinking_0002";

const LONG_THOUGHT = `The reported symptom is a 100% CPU spin, which in SwiftUI almost always means a view body is
writing state that the body itself depends on — an AttributeGraph cycle rather than a real busy
loop.

Two candidates fit. The first is the section header, which calls a function that mutates a
published property while computing its label. The second is the row view holding a reference to
the observable store below a LazyVStack boundary; every store change then invalidates every row,
and any row that writes back re-enters immediately.

The second is more likely because the spin only reproduces once the list is long enough to
virtualize. That points at the lazy boundary specifically, not at the header.

So: check whether any view below the LazyVStack holds a store reference, and whether any function
called from body writes state. The reference pattern in SessionIndexView solves exactly this by
passing plain value snapshots plus closures down instead of the store itself.`;

export const thinkingFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine({ model: "claude-opus-5" }),
  userLine("The sidebar list spins at 100% CPU once it has more than ~200 rows. Why?"),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG),
  ...streamThinking(MSG, 0, LONG_THOUGHT, 1284),
  ...streamText(
    MSG,
    1,
    "It is an AttributeGraph cycle, not a busy loop. Rows below the `LazyVStack` boundary hold a reference to the observable store, so every store change invalidates every row — and a row that writes state during `body` re-enters immediately.\n\nThe fix is the `SessionIndexView` pattern: pass value snapshots and closures below the lazy boundary, never the store itself."
  ),
  statusLine(null),
  resultLine({
    result: "AttributeGraph cycle from a store reference below the LazyVStack boundary.",
    usage: {
      input_tokens: 8,
      output_tokens: 2140,
      cache_read_input_tokens: 96400,
      output_tokens_details: { thinking_tokens: 1284 }
    }
  }),
  userLine("Now check the same thing in the tab bar."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG_REDACTED),
  blockStart(0, { type: "thinking", thinking: "", signature: "" }),
  {
    type: "system",
    subtype: "thinking_tokens",
    estimated_tokens: 640,
    estimated_tokens_delta: 640,
    uuid: uid("tt")
  } as ProtocolLine,
  assistantThinking(MSG_REDACTED, ""),
  blockStop(0),
  ...streamText(
    MSG_REDACTED,
    1,
    "`TabItemView` is on the keystroke path, so it is worse: it re-renders on every character typed. It already avoids the store reference, but it recomputes its title attributes each pass — cache those."
  ),
  statusLine(null),
  resultLine({
    result: "TabItemView avoids the store reference but recomputes title attributes per keystroke.",
    usage: {
      input_tokens: 6,
      output_tokens: 980,
      output_tokens_details: { thinking_tokens: 640 }
    }
  })
];
