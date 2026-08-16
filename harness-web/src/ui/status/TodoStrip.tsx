import { useState } from "react";
import type { TodoItem } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight } from "../Icons";

export function TodoStrip({ todos }: { todos: TodoItem[] }) {
  const copy = useCopy();
  const [open, setOpen] = useState(false);
  if (todos.length === 0) return null;

  const done = todos.filter((todo) => todo.status === "completed").length;
  const current = todos.find((todo) => todo.status === "in_progress");

  return (
    <div className={`todo-strip${open ? " is-open" : ""}`}>
      <button
        type="button"
        className="todo-strip-head"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
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
      {open ? (
        <ul className="todo-strip-list">
          {todos.map((todo, i) => (
            <li key={i} className={`todo-item is-${todo.status}`}>
              <span className="todo-mark" aria-hidden="true">
                {todo.status === "completed" ? "✓" : todo.status === "in_progress" ? "●" : "○"}
              </span>
              <span className="todo-text">{todo.content}</span>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
