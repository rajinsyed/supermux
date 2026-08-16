import { useCallback, useEffect, useMemo, useState } from "react";
import type { PendingPermission } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Check, Sparkle } from "../Icons";
import type { PermissionDecision } from "./PermissionCard";

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
        window.setTimeout(() => setActive((v) => Math.min(questions.length - 1, v + 1)), 200);
      }
    },
    [active, questions.length]
  );

  const submit = useCallback(() => {
    const payload: Record<string, string> = {};
    for (const question of questions) {
      const free = other[question.question]?.trim();
      const picked = answers[question.question] ?? [];
      const value = free && free.length > 0 ? free : picked.join(", ");
      if (value) payload[question.question] = value;
    }
    onDecide({
      behavior: "allow",
      updatedInput: { questions: request.input.questions, answers: payload }
    });
  }, [answers, other, onDecide, questions, request.input.questions]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA")) return;
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
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [current, submit, toggle]);

  const answeredCount = questions.filter((q) => {
    const free = other[q.question]?.trim();
    return (answers[q.question]?.length ?? 0) > 0 || (free && free.length > 0);
  }).length;

  return (
    <section className="question-card" role="alertdialog" aria-live="assertive">
      <header className="question-head">
        <span className="question-icon">
          <Sparkle size={13} />
        </span>
        <div className="question-title">
          <span className="question-badge">{copy("supermux.harness.question.badge")}</span>
          <h3>{request.title ?? request.display_name ?? "Claude has a question"}</h3>
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
                    placeholder={copy("supermux.harness.question.otherPlaceholder")}
                    value={other[question.question] ?? ""}
                    onChange={(event) =>
                      setOther((prev) => ({ ...prev, [question.question]: event.target.value }))
                    }
                  />
                </div>
              ) : (
                <div className="question-answer">
                  {selected.join(", ") ||
                    other[question.question] ||
                    (question.options ?? []).map((o) => o.label).join(" · ")}
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
          onClick={() => onDecide({ behavior: "deny", message: "Dismissed" })}
        >
          {copy("supermux.harness.question.dismiss")}
        </button>
      </footer>
    </section>
  );
}
