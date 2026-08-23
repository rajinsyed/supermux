import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import type { PendingPermission } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Check, ChevronRight, Sparkle } from "../Icons";
import { prefersReducedMotion } from "../motion";
import type { PermissionDecision } from "./PermissionCard";
import { useCardKeys } from "./useCardKeys";

interface QuestionOption {
  label: string;
  description?: string;
}

interface QuestionSpec {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options?: QuestionOption[];
}

const ADVANCE_MS = 200;

/**
 * The AskUserQuestion card.
 *
 * Round 5 rendered every question at once, which is what the round-6 report
 * ("looks so ugly… redesign a minimal clean design for it") was looking at: a
 * card the height of the pane, with an all-caps orange kicker over every
 * section, boxy full-width option rows carrying bordered number squares, and —
 * the worst of it — a "Not answered yet" line holding open a dead section for
 * every question the user had not reached. Three questions produced three
 * headings, two placeholders, and one live list.
 *
 * It is one question at a time now, in Beautiful UI's approval-card shape: a
 * tight header (what this is, what is being asked, where you are in it), a
 * single column of quiet option rows that only light up when chosen, and a small
 * footer. The dead sections are replaced by a stepper — position, per-step
 * answered marks, and two arrows — which occupies one 20px row instead of one
 * empty block per unasked question.
 *
 * Adapted into the token system by hand; nothing is imported. The selection
 * grammar is the pane's own (accent border + faint accent bed + a check), the
 * same one the menu kit's active row and the rewind dialog's armed checkbox
 * wear, so a chosen thing looks chosen everywhere.
 *
 * NOTHING about the protocol changes. `submit` still merges picked options with
 * free text per question and sends the same `{ questions, answers }` shape, Skip
 * still denies with the same message, and the 1–9 / Enter / Space bindings are
 * unchanged. This is a layout and a skin.
 */
export function QuestionCard({
  pending,
  onDecide
}: {
  pending: PendingPermission;
  onDecide: (decision: PermissionDecision) => void;
}) {
  const copy = useCopy();
  const request = pending.request;
  const questions = useMemo<QuestionSpec[]>(() => {
    const raw = request.input.questions;
    return Array.isArray(raw) ? (raw as unknown as QuestionSpec[]) : [];
  }, [request.input.questions]);

  const [active, setActive] = useState(0);
  const [answers, setAnswers] = useState<Record<string, string[]>>({});
  const [other, setOther] = useState<Record<string, string>>({});
  /** Questions whose free-text row has been opened, so it survives a step away. */
  const [otherOpen, setOtherOpen] = useState<Record<string, boolean>>({});
  const cardRef = useRef<HTMLElement>(null);
  const headingId = useId();
  // Set when auto-advance moves the active question, so focus follows the card
  // instead of being left wherever the pointer/composer put it.
  const claimFocus = useRef(true);

  const current = questions[active];

  const answerFor = useCallback(
    (question: QuestionSpec) => mergeAnswer(answers[question.question] ?? [], other[question.question]),
    [answers, other]
  );

  const goTo = useCallback(
    (index: number) => {
      claimFocus.current = true;
      setActive(Math.max(0, Math.min(questions.length - 1, index)));
    },
    [questions.length]
  );

  const toggle = useCallback(
    (question: QuestionSpec, label: string) => {
      setAnswers((prev) => {
        const existing = prev[question.question] ?? [];
        if (question.multiSelect) {
          const next = existing.includes(label)
            ? existing.filter((v) => v !== label)
            : existing.concat(label);
          return { ...prev, [question.question]: next };
        }
        return { ...prev, [question.question]: [label] };
      });
      if (!question.multiSelect && active < questions.length - 1) {
        window.setTimeout(() => {
          claimFocus.current = true;
          setActive((v) => Math.min(questions.length - 1, v + 1));
        }, ADVANCE_MS);
      }
    },
    [active, questions.length]
  );

  // Moving to the next question must also move focus there: leaving it in the
  // composer means the next 1–9 keypress is typed as text instead of answering.
  // `preventScroll` keeps the browser from fighting the follow-lock, so the
  // scroll is done explicitly afterwards — otherwise focus lands below the fold
  // on a short pane and the user answers a question they cannot see.
  useEffect(() => {
    if (!claimFocus.current) return;
    claimFocus.current = false;
    const first = cardRef.current?.querySelector<HTMLElement>(
      ".question-item.is-active .option"
    );
    if (!first) return;
    first.focus({ preventScroll: true });
    first.scrollIntoView({ block: "nearest", behavior: prefersReducedMotion() ? "auto" : "smooth" });
  }, [active]);

  const submit = useCallback(() => {
    const payload: Record<string, string> = {};
    for (const question of questions) {
      const value = mergeAnswer(answers[question.question] ?? [], other[question.question]);
      if (value) payload[question.question] = value;
    }
    if (Object.keys(payload).length === 0) return;
    onDecide({
      behavior: "allow",
      updatedInput: { questions: request.input.questions, answers: payload }
    });
  }, [answers, other, onDecide, questions, request.input.questions]);

  const onKey = useCallback(
    (event: KeyboardEvent) => {
      if (!current) return;
      const digit = Number.parseInt(event.key, 10);
      if (Number.isFinite(digit) && digit >= 1 && digit <= (current.options?.length ?? 0)) {
        event.preventDefault();
        toggle(current, current.options![digit - 1].label);
        return;
      }
      // The stepper's arrows, from the keyboard. Only claimed when there is
      // somewhere to go, so a single-question card leaves ←/→ alone.
      if (questions.length > 1 && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
        event.preventDefault();
        goTo(active + (event.key === "ArrowRight" ? 1 : -1));
        return;
      }
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        submit();
      }
    },
    [active, current, goTo, questions.length, submit, toggle]
  );

  useCardKeys(cardRef, onKey);

  // An option is a toggle: Space flips it, Enter submits the card. The browser
  // fires click for BOTH on a <button>, so Enter is intercepted here — otherwise
  // the auto-advance that focuses an option makes the card unsubmittable by
  // keyboard, which is the whole point of the numbered shortcuts.
  const onOptionKey = useCallback(
    (event: React.KeyboardEvent<HTMLButtonElement>) => {
      if (event.key !== "Enter" || event.shiftKey || event.metaKey || event.ctrlKey) return;
      event.preventDefault();
      submit();
    },
    [submit]
  );

  const answeredCount = questions.filter((q) => answerFor(q).length > 0).length;
  const multi = questions.length > 1;
  const selected = current ? answers[current.question] ?? [] : [];
  const freeText = current ? other[current.question] ?? "" : "";
  const showOther = current ? (otherOpen[current.question] ?? false) || freeText.length > 0 : false;

  return (
    <section
      className="question-card"
      role="alertdialog"
      aria-live="assertive"
      aria-labelledby={headingId}
      ref={cardRef}
    >
      <header className="question-head">
        <span className="question-icon">
          <Sparkle size={13} />
        </span>
        <div className="question-title">
          <span className="question-badge">{copy("supermux.harness.question.badge")}</span>
          <h3 id={headingId}>
            {request.title ?? request.display_name ?? copy("supermux.harness.question.title")}
          </h3>
        </div>
        {multi ? (
          /* The stepper replaces the two "Not answered yet" blocks: position,
             one mark per question saying whether it has an answer, and the two
             ways to move. One row, whatever the question count. */
          <nav className="q-steps" aria-label={copy("supermux.harness.question.badge")}>
            <button
              type="button"
              className="q-step-arrow"
              onClick={() => goTo(active - 1)}
              disabled={active === 0}
              title={copy("supermux.harness.question.previous")}
              aria-label={copy("supermux.harness.question.previous")}
            >
              <ChevronRight size={11} />
            </button>
            <span className="q-step-dots">
              {questions.map((question, index) => {
                const done = answerFor(question).length > 0;
                return (
                  <button
                    key={question.question}
                    type="button"
                    className={`q-step-dot${index === active ? " is-active" : ""}${
                      done ? " is-done" : ""
                    }`}
                    onClick={() => goTo(index)}
                    aria-current={index === active ? "step" : undefined}
                    aria-label={copy(
                      done
                        ? "supermux.harness.question.stepAnswered"
                        : "supermux.harness.question.stepUnanswered",
                      { index: index + 1 }
                    )}
                  />
                );
              })}
            </span>
            <button
              type="button"
              className="q-step-arrow"
              onClick={() => goTo(active + 1)}
              disabled={active === questions.length - 1}
              title={copy("supermux.harness.question.next")}
              aria-label={copy("supermux.harness.question.next")}
            >
              <ChevronRight size={11} />
            </button>
          </nav>
        ) : null}
      </header>

      {current ? (
        <div className="question-item is-active" data-index={active}>
          <div className="q-prompt">
            {/* One caption line, not three stacked ones: where you are, what
                this question is about, and whether it takes more than one
                answer are all the same tier of information. The kicker was an
                all-caps ORANGE label on its own row and the loudest thing in
                the card; the QUESTION is what carries the weight now. */}
            {multi || current.header || current.multiSelect ? (
              <span className="q-caption">
                {multi ? (
                  <span className="q-position tnum">
                    {copy("supermux.harness.question.step", {
                      index: active + 1,
                      total: questions.length
                    })}
                  </span>
                ) : null}
                {current.header ? <span className="q-kicker">{current.header}</span> : null}
                {current.multiSelect ? (
                  <span className="q-hint">{copy("supermux.harness.question.selectMultiple")}</span>
                ) : null}
              </span>
            ) : null}
            <p className="q-question">{current.question}</p>
          </div>

          <div className="question-options" role="group" aria-labelledby={headingId}>
            {(current.options ?? []).map((option, optionIndex) => {
              const on = selected.includes(option.label);
              return (
                <button
                  key={option.label}
                  type="button"
                  className={`option${on ? " is-on" : ""}`}
                  onClick={() => toggle(current, option.label)}
                  onKeyDown={onOptionKey}
                  aria-pressed={on}
                >
                  {/* The affordance is a hairline ring that fills with the
                      accent when chosen — subtle until it matters. A square is
                      drawn for multi-select and a circle for single, which is
                      the one honest way to say "you may pick more than one"
                      without a sentence. */}
                  <span
                    className={`option-mark${current.multiSelect ? " is-multi" : ""}`}
                    aria-hidden="true"
                  >
                    {on ? <Check size={9} /> : null}
                  </span>
                  <span className="option-text">
                    <span className="option-label">{option.label}</span>
                    {option.description ? (
                      <span className="option-desc">{option.description}</span>
                    ) : null}
                  </span>
                  {/* The number key, printed as a bare glyph rather than in a
                      bordered box: it is a hint about the keyboard, not a
                      second control beside the one it labels. */}
                  <span className="option-key tnum" aria-hidden="true">
                    {optionIndex + 1}
                  </span>
                </button>
              );
            })}

            {showOther ? (
              <input
                className="question-other"
                aria-label={copy("supermux.harness.question.other")}
                placeholder={copy("supermux.harness.question.otherPlaceholder")}
                value={freeText}
                autoFocus={freeText.length === 0}
                onChange={(event) =>
                  setOther((prev) => ({ ...prev, [current.question]: event.target.value }))
                }
                onKeyDown={(event) => {
                  if (event.key !== "Enter" || event.shiftKey) return;
                  event.preventDefault();
                  submit();
                }}
              />
            ) : (
              /* A permanently-open text field under a three-option question read
                 as a fourth, emptier option. It is a row that opens one. */
              <button
                type="button"
                className="option is-other"
                onClick={() =>
                  setOtherOpen((prev) => ({ ...prev, [current.question]: true }))
                }
              >
                <span className="option-mark" aria-hidden="true" />
                <span className="option-text">
                  <span className="option-label">
                    {copy("supermux.harness.question.otherRow")}
                  </span>
                </span>
              </button>
            )}

            {selected.length > 0 && freeText.trim().length > 0 ? (
              // Both were expressed, so both are sent — say so, rather than
              // leaving chips ticked next to text and no clue which wins.
              <span className="question-merged">
                {copy("supermux.harness.question.willSend", {
                  answer: mergeAnswer(selected, freeText)
                })}
              </span>
            ) : null}
          </div>
        </div>
      ) : null}

      <footer className="question-actions">
        <button
          type="button"
          className="btn btn-primary"
          onClick={submit}
          disabled={answeredCount === 0}
        >
          {copy("supermux.harness.question.submit")}
          <kbd>⏎</kbd>
        </button>
        <span className="permission-spacer" />
        <button
          type="button"
          className="btn btn-ghost"
          onClick={() =>
            onDecide({ behavior: "deny", message: copy("supermux.harness.question.dismissed") })
          }
        >
          {copy("supermux.harness.question.dismiss")}
        </button>
      </footer>
    </section>
  );
}

/**
 * A question can be answered by picking options, by typing, or by both. Letting
 * free text silently win drops selections the user can still see ticked, so the
 * submitted value is always everything they expressed, in the order they see it.
 */
function mergeAnswer(picked: string[], free: string | undefined): string {
  const typed = free?.trim() ?? "";
  return picked.concat(typed.length > 0 ? [typed] : []).join(", ");
}
