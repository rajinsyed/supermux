import { useEffect, useRef, useState } from "react";
import type { TodoItem } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight } from "../Icons";
import { Disclosure } from "../primitives/Disclosure";

export function TodoStrip({ todos }: { todos: TodoItem[] }) {
  const copy = useCopy();
  const [open, setOpen] = useState(false);
  const list = useRef<HTMLUListElement>(null);

  // The list is capped and scrolls, so on a long plan the step you are actually
  // on can open below the fold — the one thing the strip exists to show. It is
  // brought into view on expand and whenever the current step moves.
  useEffect(() => {
    if (!open) return;
    let innerFrame = 0;
    const outerFrame = requestAnimationFrame(() => {
      innerFrame = requestAnimationFrame(() => {
        const node = list.current?.querySelector<HTMLElement>(".todo-item.is-in_progress");
        node?.scrollIntoView({ block: "nearest" });
      });
    });
    return () => {
      cancelAnimationFrame(outerFrame);
      if (innerFrame) cancelAnimationFrame(innerFrame);
    };
  }, [open, todos]);

  if (todos.length === 0) return null;

  const done = todos.filter((todo) => todo.status === "completed").length;
  const current = todos.find((todo) => todo.status === "in_progress");

  return (
    // The strip is one dense line above the composer, so its name lives in the
    // region label rather than costing a visible column of chrome.
    <div
      className={`todo-strip${open ? " is-open" : ""}`}
      role="region"
      aria-label={copy("supermux.harness.todo.title")}
    >
      <button
        type="button"
        className="todo-strip-head"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-label={
          open ? copy("supermux.harness.todo.collapse") : copy("supermux.harness.todo.expand")
        }
      >
        {open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
        <span className="todo-segments" aria-hidden="true">
          {todos.map((todo, i) => (
            <span key={i} className={`todo-seg is-${todo.status}`} />
          ))}
        </span>
        <span className="todo-current">{current?.activeForm ?? current?.content ?? todos[todos.length - 1]?.content}</span>
        <span className="todo-count tnum">
          {copy("supermux.harness.todo.progress", { done, total: todos.length })}
        </span>
      </button>
      <Disclosure open={open}>
        <ul className="todo-strip-list" ref={list}>
          {todos.map((todo, i) => (
            <li key={i} className={`todo-item is-${todo.status}`}>
              <span className="todo-mark" aria-hidden="true">
                {todo.status === "completed" ? "✓" : todo.status === "in_progress" ? "●" : "○"}
              </span>
              <span className="todo-text">{todo.content}</span>
            </li>
          ))}
        </ul>
      </Disclosure>
    </div>
  );
}
