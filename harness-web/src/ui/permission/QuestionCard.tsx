import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import type { PendingPermission } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Check, Sparkle } from "../Icons";
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
 * A question can be answered by picking options, by typing, or by both. Letting
 * free text silently win drops selections the user can still see ticked, so the
 * submitted value is always everything they expressed, in the order they see it.
 */
function mergeAnswer(picked: string[], free: string | undefined): string {
  const typed = free?.trim() ?? "";
  return picked.concat(typed.length > 0 ? [typed] : []).join(", ");
}

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
  const cardRef = useRef<HTMLElement>(null);
  const headingId = useId();
  // Set when auto-advance moves the active question, so focus follows the card
  // instead of being left wherever the pointer/composer put it.
  const claimFocus = useRef(true);

  const current = questions[active];

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
  useEffect(() => {
    if (!claimFocus.current) return;
    claimFocus.current = false;
    const first = cardRef.current?.querySelector<HTMLElement>(
      ".question-item.is-active .option"
    );
    first?.focus({ preventScroll: true });
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
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        submit();
      }
    },
    [current, submit, toggle]
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

  const answeredCount = questions.filter(
    (q) => mergeAnswer(answers[q.question] ?? [], other[q.question]).length > 0
  ).length;

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
        {questions.length > 1 ? (
          <span className="question-progress tnum">
            {answeredCount}/{questions.length}
          </span>
        ) : null}
      </header>

      <div className="question-list">
        {questions.map((question, index) => {
          const selected = answers[question.question] ?? [];
          const answer = mergeAnswer(selected, other[question.question]);
          const isActive = index === active;
          return (
            <div
              key={question.question}
              className={`question-item${isActive ? " is-active" : ""}`}
              onFocusCapture={() => setActive(index)}
            >
              <button
                type="button"
                className="question-prompt"
                onClick={() => setActive(index)}
                aria-expanded={isActive}
              >
                {question.header ? <span className="question-header">{question.header}</span> : null}
                <span className="question-text">{question.question}</span>
                {question.multiSelect ? (
                  <span className="question-hint">
                    {copy("supermux.harness.question.selectMultiple")}
                  </span>
                ) : null}
              </button>
              {isActive ? (
                <div className="question-options">
                  {(question.options ?? []).map((option, optionIndex) => {
                    const on = selected.includes(option.label);
                    return (
                      <button
                        key={option.label}
                        type="button"
                        className={`option${on ? " is-on" : ""}`}
                        onClick={() => toggle(question, option.label)}
                        onKeyDown={onOptionKey}
                        aria-pressed={on}
                      >
                        <span className="option-key tnum">{optionIndex + 1}</span>
                        <span className="option-text">
                          <span className="option-label">{option.label}</span>
                          {option.description ? (
                            <span className="option-desc">{option.description}</span>
                          ) : null}
                        </span>
                        {on ? <Check size={12} className="option-check" /> : null}
                      </button>
                    );
                  })}
                  <input
                    className="question-other"
                    aria-label={copy("supermux.harness.question.other")}
                    placeholder={copy("supermux.harness.question.otherPlaceholder")}
                    value={other[question.question] ?? ""}
                    onChange={(event) =>
                      setOther((prev) => ({ ...prev, [question.question]: event.target.value }))
                    }
                    onKeyDown={(event) => {
                      if (event.key !== "Enter" || event.shiftKey) return;
                      event.preventDefault();
                      submit();
                    }}
                  />
                  {selected.length > 0 && (other[question.question] ?? "").trim().length > 0 ? (
                    // Both were expressed, so both are sent — say so, rather than
                    // leaving chips ticked next to text and no clue which wins.
                    <span className="question-merged">
                      {copy("supermux.harness.question.willSend", { answer })}
                    </span>
                  ) : null}
                </div>
              ) : answer ? (
                <div className="question-answer">
                  <span className="answer-chip">
                    <Check size={11} />
                    {answer}
                  </span>
                </div>
              ) : (
                <div className="question-answer is-unanswered">
                  {copy("supermux.harness.question.unanswered")}
                </div>
              )}
            </div>
          );
        })}
      </div>

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
