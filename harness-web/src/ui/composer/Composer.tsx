import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { resolveModel } from "../../model/helpers";
import type { ImageAttachment, QueuedMessage, SessionMeta } from "../../model/types";
import type {
  EffortLevel,
  ModelDescriptor,
  PermissionMode,
  SlashCommandDescriptor
} from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { ArrowUp, Close, Plus, Stop } from "../Icons";
import { basename } from "../format";
import { CommandItem, CommandList, MenuEmpty, MenuKeys } from "../primitives/MenuList";
import { PopoverSurface } from "../primitives/Popover";
import { ModelMenu, stepEffort } from "./ModelMenu";
import { useComposerPopover } from "./usePopover";

export interface ComposerProps {
  disabled: boolean;
  /**
   * WHY the composer is disabled, when the reason is a restart rather than a
   * missing CLI. Both states disable it, and collapsing them onto one string
   * told a user mid-restart to "Install the Claude Code CLI" — advice about
   * software they were visibly already running.
   */
  restarting?: boolean;
  running: boolean;
  awaitingPermission: boolean;
  /** A plan card is up: the composer's primary action answers it. */
  planPending: boolean;
  onPlanImplement(): void;
  onPlanRefine(text: string): void;
  onPlanKeepPlanning(): void;
  queued: QueuedMessage[];
  commands: SlashCommandDescriptor[];
  permissionMode: PermissionMode;
  /**
   * The model picker lives in the composer pill, trailing edge, beside send —
   * Cursor's grammar, and the honest one: the model is a property of the
   * message about to be sent, not of the session's chrome. Optional so the
   * composer still stands alone in tests and in the agent-view harness that
   * has no session to pick a model for.
   */
  session?: Pick<SessionMeta, "model" | "models" | "effort">;
  /** Catalog persisted from an earlier run of this binary; see modelMenuSource. */
  cachedModels?: ModelDescriptor[];
  onSetModel?(model: string, effort?: EffortLevel): void;
  draft: string;
  onDraftChange(text: string): void;
  onSend(text: string, images: ImageAttachment[]): void;
  /**
   * The composer is inside an agent view and addresses that agent.
   *
   * Three states, not two: `undefined` is the main chat, a NAME is a reachable
   * agent this message will be relayed to, and `null` is an agent view whose
   * agent has finished — where the send still works but goes to Claude, and
   * saying so is the difference between a redirect and a surprise.
   */
  agentName?: string | null;
  onInterrupt(cancelQueued: boolean): void;
  onCancelQueued(uuid: string): void;
  onCyclePermissionMode(): void;
  fetchFileSuggestions(query: string): Promise<string[]>;
  onPickFiles(): Promise<ImageAttachment[]>;
  /**
   * Hands the parent a way to put the caret here. A rewind refills the composer
   * with the message being edited, and text that appears without focus reads as
   * something that happened TO the pane rather than a field waiting for you.
   */
  registerFocus?(focus: () => void): void;
}

const MAX_HEIGHT = 260;
/**
 * One line of the composer's own box: 18px line-height plus 5px of padding
 * either side, which is `--composer-line` in dock.css. Kept in step with it by
 * tests/composerAlign.test.ts, which reads the sheet — a drift here would put
 * the pill into its multi-line alignment for an ordinary one-line draft.
 */
const SINGLE_LINE_HEIGHT = 28;

export function Composer(props: ComposerProps) {
  const copy = useCopy();
  const textarea = useRef<HTMLTextAreaElement>(null);
  const [caret, setCaret] = useState(0);
  const [images, setImages] = useState<ImageAttachment[]>([]);
  const [escArmed, setEscArmed] = useState(false);

  const { state: popover, move, reset } = useComposerPopover(
    props.draft,
    caret,
    props.commands,
    props.fetchFileSuggestions
  );

  /**
   * The live model, resolved the same way the picker's trigger resolves it —
   * against the live catalog first and the cached one behind it, because before
   * the first start `session.models` is empty and only the cache can turn a
   * selector into a descriptor with an effort scale on it. Option+,/. needs the
   * SCALE, not just the name, so a cheaper `session.model` string would leave
   * the binding dead on a pane that has not started yet.
   */
  const activeModel = props.session ? resolveModel(props.session, props.cachedModels) : undefined;

  /**
   * Autosize, and the one bit of state the ROW's alignment depends on.
   *
   * The pill centres its children on one line while the draft fits on one line,
   * and drops them to the last line once it does not (see `.composer-shell` and
   * its `:has(.is-multiline)` rule). Which of those is true is only knowable
   * after measuring, so it is written as a class here rather than guessed in
   * CSS. Measured against LINE_HEIGHT plus the box's own padding, so a draft
   * that is exactly one line long — the ordinary case, and the one the round-5
   * screenshot caught misaligned — never trips it.
   */
  useLayoutEffect(() => {
    const node = textarea.current;
    if (!node) return;
    node.style.height = "auto";
    const next = Math.min(MAX_HEIGHT, node.scrollHeight);
    node.style.height = `${next}px`;
    node.classList.toggle("is-multiline", next > SINGLE_LINE_HEIGHT);
  }, [props.draft]);

  const focus = useCallback(() => {
    const node = textarea.current;
    if (!node) return;
    node.focus();
    // The caret lands after the prefilled text, which is where editing starts.
    node.setSelectionRange(node.value.length, node.value.length);
  }, []);

  const register = props.registerFocus;
  useEffect(() => {
    register?.(focus);
  }, [focus, register]);

  // Type-to-focus, but the pending permission/question card owns the keyboard
  // while it is up: its 1–9 / A / Enter / Esc shortcuts are the whole point of
  // the inline takeover, and stealing focus here turns them into typed text.
  // A plan card is the exception — it claims only Enter and Esc, and typing IS
  // the refine path, so printable keys still belong to the composer.
  const awaitingPermission = props.awaitingPermission && !props.planPending;
  useEffect(() => {
    if (awaitingPermission) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      if (target) {
        const tag = target.tagName;
        if (tag === "INPUT" || tag === "TEXTAREA" || target.isContentEditable) return;
        if (target.closest("button, a, [role='button']")) return;
      }
      if (event.key.length !== 1) return;
      focus();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [awaitingPermission, focus]);

  const applyCompletion = useCallback(
    (value: string) => {
      const node = textarea.current;
      if (!node) return;
      const prefix = props.draft.slice(0, popover.start);
      const suffix = props.draft.slice(caret);
      // `popover.start` points AT the sigil, so the replaced range swallows it:
      // both branches must put their own back, or an accepted `/compact`
      // reaches the CLI as prose the model answers instead of a slash command.
      const insert = popover.kind === "command" ? `/${value} ` : `@${value} `;
      const next = `${prefix}${insert}${suffix}`;
      props.onDraftChange(next);
      reset();
      requestAnimationFrame(() => {
        const position = prefix.length + insert.length;
        node.setSelectionRange(position, position);
        node.focus();
        setCaret(position);
      });
    },
    [caret, popover.kind, popover.start, props, reset]
  );

  const submit = useCallback(() => {
    const text = props.draft.trim();
    // One mutation path for the plan decision: Enter and the primary button must
    // not disagree about whether typed text refines the plan or approves it.
    if (props.planPending) {
      if (text) props.onPlanRefine(text);
      else props.onPlanImplement();
      setImages([]);
      reset();
      return;
    }
    if (!text && images.length === 0) return;
    props.onSend(text, images);
    setImages([]);
    reset();
    requestAnimationFrame(() => {
      const node = textarea.current;
      if (node) node.style.height = "auto";
    });
  }, [images, props, reset]);

  const onKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
      if (popover.kind && popover.items.length > 0) {
        if (event.key === "ArrowDown") {
          event.preventDefault();
          move(1);
          return;
        }
        if (event.key === "ArrowUp") {
          event.preventDefault();
          move(-1);
          return;
        }
        if (event.key === "Tab" || (event.key === "Enter" && !event.shiftKey)) {
          event.preventDefault();
          applyCompletion(popover.items[popover.index].id);
          return;
        }
        if (event.key === "Escape") {
          event.preventDefault();
          reset();
          return;
        }
      }
      if (event.key === "Enter" && !event.shiftKey && !event.metaKey) {
        event.preventDefault();
        submit();
        return;
      }
      if (event.key === "Escape") {
        // Claimed ONLY when it actually does something here.
        //
        // It used to `preventDefault` unconditionally, which was invisible
        // while the composer was the only thing Escape meant — and became a
        // bug the moment there was a view stack to pop: with the caret in the
        // composer of an agent view, Escape was swallowed and the reader could
        // not leave the view by keyboard at all.
        //
        // An agent view never claims it: the interrupt would stop MAIN, which
        // is not what the reader is looking at, and back is what Escape means
        // everywhere else in the pane.
        if (props.planPending) {
          event.preventDefault();
          props.onPlanKeepPlanning();
        } else if (props.running && props.agentName === undefined) {
          event.preventDefault();
          props.onInterrupt(escArmed);
          setEscArmed(true);
          window.setTimeout(() => setEscArmed(false), 1600);
        }
        return;
      }
      if (event.key === "Tab" && event.shiftKey) {
        event.preventDefault();
        props.onCyclePermissionMode();
        return;
      }
      /**
       * Item 12: Option+, and Option+. step the reasoning effort with the caret
       * still in the composer — the CLI's own pair of bindings, so a user
       * arriving from the terminal keeps the reflex.
       *
       * Matched on `event.code`, NEVER on `event.key`: on macOS Option+comma
       * produces "≤" and Option+period produces "≥", so a `key === ","` test
       * matches nothing at all on the platform this pane ships on. `code` names
       * the physical key and is unaffected by the modifier's remapping.
       *
       * `preventDefault` is what keeps those two glyphs out of the draft, and it
       * runs whether or not the step lands: at the top of the scale the key must
       * still not type "≥" into the message.
       *
       * Same path as the menu and the wheel — `onSetModel` with the active
       * model's own selector — so all three can never disagree about what was
       * sent, and the trigger label repaints from the session the moment the
       * store settles.
       */
      if (event.altKey && (event.code === "Comma" || event.code === "Period")) {
        const model = activeModel;
        if (!model || !props.onSetModel) return;
        event.preventDefault();
        const next = stepEffort(model, props.session?.effort, event.code === "Period" ? 1 : -1);
        if (!next) return;
        props.onSetModel(model.value, next);
      }
    },
    [activeModel, applyCompletion, escArmed, move, popover, props, reset, submit]
  );

  const onPaste = useCallback((event: React.ClipboardEvent) => {
    const files = Array.from(event.clipboardData?.files ?? []).filter((file) =>
      file.type.startsWith("image/")
    );
    if (files.length === 0) return;
    event.preventDefault();
    for (const file of files) readImage(file, (attachment) => setImages((prev) => prev.concat(attachment)));
  }, []);

  const onDrop = useCallback((event: React.DragEvent) => {
    const files = Array.from(event.dataTransfer?.files ?? []).filter((file) =>
      file.type.startsWith("image/")
    );
    if (files.length === 0) return;
    event.preventDefault();
    for (const file of files) readImage(file, (attachment) => setImages((prev) => prev.concat(attachment)));
  }, []);

  // A restart is temporary and a missing CLI is not, so the restart reads first:
  // the pane can be mid-restart with the CLI perfectly present.
  const placeholder = props.restarting
    ? copy("supermux.harness.composer.placeholderRestarting")
    : props.disabled
      ? copy("supermux.harness.composer.placeholderNoCli")
      : props.planPending
        ? copy("supermux.harness.composer.placeholderPlan")
        : props.awaitingPermission
          ? copy("supermux.harness.composer.placeholderWaiting")
          : // WHO this message is for outranks whether Claude is busy: in an
            // agent view the send does not queue behind main's turn, it is
            // relayed to the agent, and "it will be queued" would be a lie
            // about a different destination.
            props.agentName !== undefined
            ? props.agentName === null
              ? copy("supermux.harness.agentView.composerPlaceholderDone")
              : copy("supermux.harness.agentView.composerPlaceholder", {
                  agent: props.agentName
                })
            : props.running
              ? copy("supermux.harness.composer.placeholderRunning")
              : copy("supermux.harness.composer.placeholder");

  const canSend = props.draft.trim().length > 0 || images.length > 0;

  return (
    <div className={`composer${props.awaitingPermission ? " is-waiting" : ""}`}>
      {/* Completion popover — one compact panel, no chrome above the rows.
          The kind is named once in the footer rather than in a heading, so the
          first row sits at the top edge where the eye and the arrow keys both
          start, and a two-item list is two items tall instead of four. */}
      {popover.kind ? (
        <PopoverSurface align="stretch" className={`pop-complete is-${popover.kind}`}>
          {popover.items.length === 0 ? (
            <MenuEmpty>
              {popover.kind === "command"
                ? copy("supermux.harness.composer.commandEmpty")
                : copy("supermux.harness.composer.mentionEmpty")}
            </MenuEmpty>
          ) : (
            <CommandList>
              {popover.items.map((item, index) => (
                <CommandItem
                  key={item.id}
                  label={item.label}
                  hint={item.hint}
                  detail={item.detail}
                  active={index === popover.index}
                  onPick={() => applyCompletion(item.id)}
                />
              ))}
            </CommandList>
          )}
          <div className="ui-menu-foot">
            <span className="pop-complete-kind">
              {popover.kind === "command"
                ? copy("supermux.harness.composer.commandTitle")
                : copy("supermux.harness.composer.mentionTitle")}
            </span>
            <MenuKeys keys={["↑↓", "⏎"]} />
          </div>
        </PopoverSurface>
      ) : null}

      <div className="composer-shell" onDrop={onDrop} onDragOver={(e) => e.preventDefault()}>
        {props.queued.length > 0 ? (
          <div className="queue-strip">
            {props.queued.map((message) => (
              <span key={message.uuid} className="queue-chip">
                <span className="queue-chip-label">{copy("supermux.harness.composer.queued")}</span>
                <span className="queue-chip-text">{message.text}</span>
                <button
                  type="button"
                  className="queue-chip-x"
                  onClick={() => props.onCancelQueued(message.uuid)}
                  aria-label={copy("supermux.harness.composer.cancelQueued")}
                >
                  <Close size={10} />
                </button>
              </span>
            ))}
          </div>
        ) : null}

        {images.length > 0 ? (
          <div className="attach-strip">
            {images.map((image, i) => (
              <span key={i} className="attach-chip">
                <img src={`data:${image.mediaType};base64,${image.dataBase64}`} alt="" />
                <span className="attach-name">{image.name ? basename(image.name) : "image"}</span>
                <button
                  type="button"
                  className="queue-chip-x"
                  onClick={() => setImages((prev) => prev.filter((_, index) => index !== i))}
                  aria-label={copy("supermux.harness.composer.removeAttachment")}
                >
                  <Close size={10} />
                </button>
              </span>
            ))}
          </div>
        ) : null}

        <button
          type="button"
          className="composer-attach"
          onClick={() => {
            props.onPickFiles().then((picked) => setImages((prev) => prev.concat(picked)));
          }}
          title={copy("supermux.harness.composer.attach")}
          aria-label={copy("supermux.harness.composer.attach")}
        >
          <Plus size={14} />
        </button>
        <textarea
          ref={textarea}
          className="composer-input"
          value={props.draft}
          placeholder={placeholder}
          rows={1}
          disabled={props.disabled}
          aria-label={copy("supermux.harness.a11y.composer")}
          onChange={(event) => {
            props.onDraftChange(event.target.value);
            setCaret(event.target.selectionStart ?? 0);
          }}
          onKeyUp={(event) => setCaret(event.currentTarget.selectionStart ?? 0)}
          onClick={(event) => setCaret(event.currentTarget.selectionStart ?? 0)}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
        />
        <div className="composer-actions">
          {props.session && props.onSetModel ? (
            <ModelMenu
              session={props.session}
              cachedModels={props.cachedModels}
              onSetModel={props.onSetModel}
            />
          ) : null}
          {props.planPending ? (
            // Under a pending plan the primary next action is the plan
            // decision, not a generic send: approving it is one click, and the
            // moment the user starts typing that same button refines instead.
            <button
              type="button"
              className="btn btn-primary btn-plan-action"
              onClick={() => (canSend ? props.onPlanRefine(props.draft.trim()) : props.onPlanImplement())}
            >
              {canSend
                ? copy("supermux.harness.plan.refine")
                : copy("supermux.harness.plan.implement")}
            </button>
          ) : /* Same reason the Escape hint goes: in an agent view the primary
                action is SENDING to that agent, and a Stop button there would
                interrupt main — the conversation the reader has navigated away
                from. Main's own Stop is one Escape away, on its own screen. */
          props.running && props.agentName === undefined ? (
            <button
              type="button"
              className="btn btn-stop"
              onClick={() => props.onInterrupt(true)}
              title={copy("supermux.harness.composer.stop")}
              aria-label={copy("supermux.harness.composer.stop")}
            >
              <Stop size={11} />
            </button>
          ) : (
            <button
              type="button"
              className="btn btn-send"
              onClick={submit}
              disabled={!canSend || props.disabled}
              title={copy("supermux.harness.composer.send")}
            >
              <ArrowUp size={13} />
            </button>
          )}
        </div>
      </div>
      {/* Nothing under the pill. The relay caveat that used to live here
          ("Delivered through Claude at the agent's next tool call.") appeared
          and disappeared with the agent view and shifted the whole dock as it
          did; the same sentence is still said where it is actually needed — on
          the relay's own status row in AgentChatView, at the moment a message
          is in flight. */}
    </div>
  );
}

function readImage(file: File, done: (attachment: ImageAttachment) => void): void {
  const reader = new FileReader();
  reader.onload = () => {
    const result = typeof reader.result === "string" ? reader.result : "";
    const comma = result.indexOf(",");
    if (comma === -1) return;
    done({ mediaType: file.type, dataBase64: result.slice(comma + 1), name: file.name });
  };
  reader.readAsDataURL(file);
}
