import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
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
import { ModelMenu } from "./ModelMenu";
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

  useLayoutEffect(() => {
    const node = textarea.current;
    if (!node) return;
    node.style.height = "auto";
    node.style.height = `${Math.min(MAX_HEIGHT, node.scrollHeight)}px`;
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
      }
    },
    [applyCompletion, escArmed, move, popover, props, reset, submit]
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
      {popover.kind ? (
        <div className="popover" role="listbox">
          <div className="popover-title">
            {popover.kind === "command"
              ? copy("supermux.harness.composer.commandTitle")
              : copy("supermux.harness.composer.mentionTitle")}
          </div>
          {/* A trigger that silently shows nothing reads as a broken popover.
              Saying so costs one row and answers the question the user has. */}
          {popover.items.length === 0 ? (
            <div className="popover-empty">
              {popover.kind === "command"
                ? copy("supermux.harness.composer.commandEmpty")
                : copy("supermux.harness.composer.mentionEmpty")}
            </div>
          ) : null}
          {popover.items.map((item, index) => (
            <button
              key={item.id}
              type="button"
              className={`popover-item${index === popover.index ? " is-active" : ""}`}
              role="option"
              aria-selected={index === popover.index}
              onMouseDown={(event) => {
                event.preventDefault();
                applyCompletion(item.id);
              }}
            >
              <span className="popover-label mono">{item.label}</span>
              {item.hint ? <span className="popover-hint mono">{item.hint}</span> : null}
              {item.detail ? <span className="popover-detail">{item.detail}</span> : null}
            </button>
          ))}
        </div>
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

      {/* One situational caveat only — the relay's delivery semantics, which a
          user cannot infer. Everything else (Enter to send, Esc while running
          — the status strip already says that one) earns no permanent caption
          under the composer. */}
      {props.agentName ? (
        <div className="composer-hints">
          <span className="composer-hint is-hint-relay">
            {copy("supermux.harness.agentView.relayHint")}
          </span>
          <span className="composer-hints-spacer" />
        </div>
      ) : null}
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
