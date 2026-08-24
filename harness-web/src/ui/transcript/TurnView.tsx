import { memo, useEffect, useMemo } from "react";
import { hasLiveBackgroundWork } from "../../model/tasks";
import type { Block, RelayRecord, Turn } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { Check, ChevronDown, ChevronRight, ChevronUp, XCircle } from "../Icons";
import { formatDuration } from "../format";
import {
  usePresentationOverride,
  usePresentationState,
  useWasLiveKeys
} from "../presentationState";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { WorkingDots } from "../primitives/Spinner";
import { isRelayAck } from "../views/relay";
import { BlockView } from "./BlockView";
import { useFoldGuardHost } from "./foldGuard";
import { RelayChip } from "./RelayChip";
import { UserMessage } from "./UserMessage";

function splitBlocks(turn: Turn): { work: Block[]; tail: Block[] } {
  // A failed agent attempt that a later retry replaced is the retry's history,
  // not sibling work: filtered before counts and folds, or "Failed" rows and
  // "N earlier tool calls" both report attempts the turn itself recovered from.
  const blocks = turn.blocks.filter(
    (block) => block.kind !== "tool" || block.supersededByToolUseId === undefined
  );
  let cut = blocks.length;
  for (let i = blocks.length - 1; i >= 0; i -= 1) {
    const block = blocks[i];
    if (block.kind === "text" && block.text.trim().length > 0) {
      cut = i;
      continue;
    }
    if (block.kind === "notice" || block.kind === "divider" || block.kind === "commandOutput") {
      cut = i;
      continue;
    }
    break;
  }
  return { work: blocks.slice(0, cut), tail: blocks.slice(cut) };
}

/**
 * A running turn shows only its latest work plus anything still live. Forty
 * fully-expanded tool cards push the "Working for Ns" indicator and the answer
 * itself off-screen, and the rows a user cares about while Claude works are the
 * current one and any subagent that has not finished.
 */
function isLive(block: Block): boolean {
  if (block.kind !== "tool") return false;
  if (block.status === "running" || block.status === "pending") return true;
  // A backgrounded command or an async agent returns its tool_result IMMEDIATELY
  // — "running in background", "async_launched" — so the card settles while the
  // work it launched keeps going for another minute. Judged on tool status alone
  // it is history, and the live progress card the user is watching gets folded
  // away behind "3 earlier tool calls" seconds after it appears.
  return hasLiveBackgroundWork({ blocks: [block] } as Turn);
}

function isStoppedBackgroundWork(block: Block): boolean {
  if (block.kind !== "tool" || block.subagent?.background !== true) return false;
  return block.subagent.status === "stopped" || block.subagent.status === "killed";
}

/**
 * Which work rows are folded away while the turn streams. Empty once the turn
 * settles: a settled turn shows everything (behind the fold header).
 *
 * `wasLive` remembers live background rows through their killed/stopped terminal
 * sequence. Ordinary sequential tools are never retained, so they still fold as
 * soon as the next activity replaces them.
 */
function hiddenWhileStreaming(
  work: Block[],
  settled: boolean,
  wasLive: ReadonlySet<string>
): boolean[] {
  if (settled || work.length <= 1) return work.map(() => false);

  let latestTextIndex = -1;
  let latestToolIndex = -1;
  for (let index = work.length - 1; index >= 0; index -= 1) {
    const block = work[index];
    if (latestTextIndex < 0 && block.kind === "text" && block.text.trim().length > 0) {
      latestTextIndex = index;
    }
    if (latestToolIndex < 0 && block.kind === "tool") latestToolIndex = index;
    if (latestTextIndex >= 0 && latestToolIndex >= 0) break;
  }
  const fallbackIndex = latestTextIndex < 0 && latestToolIndex < 0 ? work.length - 1 : -1;

  // The default live surface is at most two status rows: Claude's latest text
  // update and the latest tool call. Anything still running stays on screen
  // wherever it sits, and a user interjection stays visible so a just-sent
  // message never disappears behind the overflow control.
  return work.map(
    (block, index) =>
      index !== latestTextIndex &&
      index !== latestToolIndex &&
      index !== fallbackIndex &&
      block.kind !== "userText" &&
      !isLive(block) &&
      !(wasLive.has(block.key) && isStoppedBackgroundWork(block))
  );
}

export const TurnView = memo(function TurnView({
  turn,
  position,
  total,
  generation = 0,
  onRewind,
  onFoldChange,
  relay
}: {
  turn: Turn;
  /** Kept for caller compatibility; folding no longer exempts the last turn. */
  isLast?: boolean;
  /** Absolute position metadata for screen readers in a virtualized log. */
  position?: number;
  total?: number;
  /** Conversation generation disambiguating reused wire block identities. */
  generation?: number;
  /** Given the turn's user-message uuid; absent when the pane cannot rewind. */
  onRewind?: (uuid: string) => void;
  /** Shared reducer action in production; direct renders use pane UI state. */
  onFoldChange?: (folded: boolean) => void;
  /**
   * This turn carries a message the user addressed to an AGENT, which the pane
   * routed through main. It is not a conversation with Claude, so it does not
   * get a bubble and its "RELAYED" answer does not get an answer's weight.
   */
  relay?: RelayRecord;
}) {
  const copy = useCopy();
  const [localFoldOverride, setLocalFoldOverride] = usePresentationOverride(
    `turn:${turn.id}:fold`
  );
  const [showEarlier, setShowEarlier] = usePresentationState(
    `turn:${turn.id}:streaming-overflow`,
    false
  );
  const [rememberedHold, setRememberedHold] = usePresentationState(
    `turn:${turn.id}:reader-hold`,
    false
  );
  const { work, tail } = useMemo(() => splitBlocks(turn), [turn.blocks]);

  const settled = turn.state !== "streaming";
  /**
   * Something inside this turn is open because the reader opened it. Automatic
   * folding yields to that choice, while an explicit click on the turn header
   * remains authoritative in either direction.
   */
  const { held, Provider: FoldGuardProvider } = useFoldGuardHost();
  useEffect(() => {
    if (held !== rememberedHold) setRememberedHold(held);
  }, [held, rememberedHold, setRememberedHold]);
  const explicitFold = onFoldChange ? turn.foldOverride : localFoldOverride;
  const folded =
    work.length > 0 &&
    (explicitFold === true ||
      (explicitFold !== false && settled && turn.folded && !held && !rememberedHold));

  const currentLiveKeys = useMemo(
    () => work.filter(isLive).map((block) => block.key),
    [work]
  );
  const stoppedBackgroundKeys = useMemo(
    () => work.filter(isStoppedBackgroundWork).map((block) => block.key),
    [work]
  );
  const reachableWorkKeys = useMemo(() => work.map((block) => block.key), [work]);
  const wasLive = useWasLiveKeys(
    turn.id,
    currentLiveKeys,
    stoppedBackgroundKeys,
    reachableWorkKeys
  );
  const hidden = useMemo(
    () => hiddenWhileStreaming(work, settled, wasLive),
    [work, settled, wasLive]
  );
  const earlierCount = useMemo(() => {
    const earlier = work.filter((_, i) => hidden[i]);
    const tools = earlier.filter((b) => b.kind === "tool").length;
    return tools > 0 ? tools : earlier.length;
  }, [work, hidden]);
  /**
   * The turn's own span when it is the larger number: a turn that settled and
   * REOPENED (a workflow's summary leg) carries only its LAST result's
   * duration_ms, and "Worked for 2s" over a 40-second run under-reports the
   * very work the fold is summarizing.
   */
  const span = turn.endedAtMs !== undefined ? turn.endedAtMs - turn.startedAtMs : undefined;
  const reported = turn.result?.durationMs;
  const duration =
    reported !== undefined && span !== undefined
      ? Math.max(reported, span)
      : reported ?? span;

  const durationText = formatDuration(duration, copy);
  const foldLabel =
    turn.state === "aborted"
      ? copy("supermux.harness.turn.stoppedAfter", { duration: durationText })
      : turn.state === "error"
        ? copy("supermux.harness.turn.failedAfter", { duration: durationText })
        : copy("supermux.harness.turn.workedFor", { duration: durationText });

  return (
    <article
      className={`turn is-${turn.state}${relay ? " is-relay" : ""}`}
      data-turn-id={turn.id}
      aria-posinset={position}
      aria-setsize={total}
    >
      {relay ? (
        <RelayChip relay={relay} />
      ) : turn.command ? (
        /* A local slash command (`/model opus[1m]`). Not a conversation with
           Claude, so no bubble: a small quiet chip naming the command, with its
           stdout rendered as dim result lines in the body below. */
        <div className="command-chip mono" title={copy("supermux.harness.turn.commandChip")}>
          <span className="command-chip-name">{turn.command.name}</span>
          {turn.command.args ? (
            <span className="command-chip-args">{turn.command.args}</span>
          ) : null}
        </div>
      ) : turn.userText !== undefined ? (
        <UserMessage
          text={turn.userText}
          images={turn.userImages}
          stateKey={`turn:${turn.id}:user`}
          onRewind={
            onRewind && turn.userUuid ? () => onRewind(turn.userUuid as string) : undefined
          }
        />
      ) : null}

      <div className="turn-body">
        {work.length > 0 ? (
          <>
            {/* One button slot for both states: the settled fold header and the
                streaming overflow expander swap PROPS on the same element, so
                settling never rebuilds the sibling work tree below. */}
            {settled || folded ? (
              /**
               * The settled turn's summary row: "Worked for 2m 30s", and
               * nothing else.
               *
               * It used to lead with a chevron and trail with "1 earlier tool
               * call" — a count of rows the reader is one click from simply
               * SEEING, printed permanently on a line whose job is to state the
               * outcome. Round 6 drops it: the fold's own contents are the
               * honest answer to "how much work", and the streaming overflow
               * (below) still counts, because there the hidden rows are the
               * point of the control.
               *
               * The affordance moved to the trailing edge and reveals on hover
               * or focus — the CSS carries that, but the ROW stays the button,
               * so the whole line is the target and keyboard reach is
               * unchanged. `aria-expanded` lives here, on the thing that
               * actually toggles.
               *
               * Round 7: the reveal is hover/focus in EVERY state. Round 6
               * pinned the glyph on a folded turn "because nothing else says
               * there is hidden content" — but a scrolled-back transcript is
               * all folded turns, so the pin put the column of controls
               * straight back. `is-folded` stays on the class list because the
               * chevron's DIRECTION is keyed off it; nothing pins it visible.
               */
              <button
                type="button"
                className={`fold-head${folded ? " is-folded" : ""}`}
                onClick={() => {
                  const next = !folded;
                  if (onFoldChange) onFoldChange(next);
                  else setLocalFoldOverride(next);
                }}
                aria-expanded={!folded}
              >
                <span className="fold-label">
                  {settled ? (
                    foldLabel
                  ) : (
                    <Elapsed
                      className="tnum"
                      startedAtMs={turn.startedAtMs}
                      prefix={`${copy("supermux.harness.status.workingFor", { duration: "" }).trim()} `}
                    />
                  )}
                </span>
                {/* Not a nested button — a button inside a button is invalid and
                    unfocusable. It is the row's own trailing glyph: bare, with
                    no bed of its own, because the row it sits on is a sentence
                    rather than a toolbar. */}
                <span className="fold-toggle" aria-hidden="true">
                  {folded ? <ChevronDown size={12} /> : <ChevronUp size={12} />}
                </span>
              </button>
            ) : earlierCount > 0 ? (
              <button
                type="button"
                className="work-overflow"
                onClick={() => setShowEarlier((v) => !v)}
                aria-expanded={showEarlier}
              >
                {showEarlier ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
                <span className="tnum">
                  {plural(
                    copy,
                    earlierCount,
                    "supermux.harness.turn.previousToolCallsOne",
                    "supermux.harness.turn.previousToolCalls"
                  )}
                </span>
              </button>
            ) : null}
            {/* Streaming overflow keeps one stable tree while the turn is live.
                A completed or explicitly closed fold unmounts it completely;
                reader choices below are restored from the pane presentation store. */}
            {!folded ? (
              <div className="turn-work">
                <FoldGuardProvider>
                  {work.map((block, i) => (
                    <Disclosure
                      key={block.key}
                      open={!hidden[i] || showEarlier}
                      keepMounted
                      // While the turn streams, "which row is the tail" changes
                      // on every step; animating each superseded row's collapse
                      // above a bottom-pinned scroller is the reported flash.
                      // The reader's own expander (`showEarlier`) and the
                      // settle boundary still animate.
                      instant={!settled && !showEarlier}
                      className={hidden[i] ? "turn-work-hidden" : "turn-work-item"}
                    >
                      <BlockView block={block} live={!settled && !hidden[i]} generation={generation} />
                    </Disclosure>
                  ))}
                </FoldGuardProvider>
              </div>
            ) : null}
          </>
        ) : null}

        {/* A relay turn's answer is the single word "RELAYED" — main confirming
            it did the plumbing. Shown as an assistant message it reads as
            Claude replying to the user with a shout, in a turn whose actual
            content is elsewhere. It is compacted to a receipt beside the chip;
            anything main says BEYOND the acknowledgment still renders, because
            then it is telling the user something. */}
        {tail.map((block) =>
          relay && block.kind === "text" && isRelayAck(block.text) ? (
            <div key={block.key} className="relay-ack">
              <Check size={10} className="mark-ok" />
              {copy("supermux.harness.relay.ack")}
            </div>
          ) : (
            <BlockView key={block.key} block={block} generation={generation} />
          )
        )}

        {turn.state === "streaming" && !folded ? (
          <div className="turn-live">
            <WorkingDots>
              <Elapsed
                className="turn-live-label tnum"
                startedAtMs={turn.startedAtMs}
                prefix={`${copy("supermux.harness.status.workingFor", { duration: "" }).trim()} `}
              />
            </WorkingDots>
          </div>
        ) : null}

        {turn.state === "aborted" ? (
          <div className="turn-interrupted">
            <XCircle size={12} />
            {copy("supermux.harness.turn.interrupted")}
          </div>
        ) : null}
      </div>
    </article>
  );
});
