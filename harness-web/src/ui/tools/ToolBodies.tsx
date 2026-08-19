import { getBridge } from "../../bridge";
import type { JsonObject, StructuredPatchHunk } from "../../protocol/types";
import type { ToolBlock } from "../../model/types";
import { plural, useCopy, type CopyFn } from "../CopyContext";
import { languageForPath, shortenPath } from "../format";
import { AnsiOutput } from "../primitives/AnsiOutput";
import { CodeBlock } from "../primitives/CodeBlock";
import { DiffView } from "../primitives/DiffView";
import { Markdown } from "../primitives/Markdown";
import { mcpServerName } from "./toolMeta";

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function patchOf(structured: JsonObject | undefined): StructuredPatchHunk[] {
  const raw = structured?.structuredPatch;
  return Array.isArray(raw) ? (raw as unknown as StructuredPatchHunk[]) : [];
}

/**
 * A tool that FAILED usually carries no structured payload at all: the CLI sends
 * the failure as a plain `content` string with `is_error: true`. Every renderer
 * that keys off `block.structured` therefore has to end here rather than at
 * `null`, or the card auto-opens on an error and shows an empty body — dropping
 * the one string (the ENOENT path, the rejected edit) the reader opened it for.
 */
function ResultText({ block }: { block: ToolBlock }) {
  const text = block.resultText;
  if (!text || text.trim().length === 0) return null;
  const error = block.status === "error";
  return (
    <AnsiOutput
      text={text}
      tone={error ? "error" : "default"}
      maxLines={14}
      stateKey={`block:${block.key}:result`}
      // A failure is prose (`ENOENT … open '/very/long/path'`); wrapping it keeps
      // the path on screen. Non-error text may be aligned output, so it scrolls.
      wrap={error}
    />
  );
}

function ResultFallback({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const empty = !block.resultText || block.resultText.trim().length === 0;
  // A settled card is expandable and, for an error, auto-open — so it always
  // says something. Only a card still waiting on its result may render nothing.
  if (empty && (block.status === "pending" || block.status === "running")) return null;
  return (
    <div className="tool-body">
      {empty ? (
        <div className="tool-waiting mono">{copy("supermux.harness.tool.noOutput")}</div>
      ) : (
        <ResultText block={block} />
      )}
    </div>
  );
}

/**
 * A failure can also arrive alongside a payload — a rejected Edit still carries
 * its old/new strings — so the message is appended to the drawn body too, not
 * only used as the fallback.
 */
function ErrorText({ block }: { block: ToolBlock }) {
  if (block.status !== "error") return null;
  return <ResultText block={block} />;
}

export function BashBody({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const command = str(block.input.command);
  const stdout = str(block.structured?.stdout);
  const stderr = str(block.structured?.stderr);
  const output = block.resultText ?? "";
  const body = stdout ?? (stderr ? "" : output);
  return (
    <div className="tool-body">
      {command ? (
        <CodeBlock
          code={command}
          language="bash"
          dense
          maxLines={10}
          stateKey={`block:${block.key}:command`}
        />
      ) : null}
      {block.status === "running" && !body && !stderr ? (
        <div className="tool-waiting mono">{copy("supermux.harness.tool.running")}…</div>
      ) : null}
      {body !== undefined && body.length > 0 ? (
        <AnsiOutput text={body} stateKey={`block:${block.key}:stdout`} streaming={block.streaming} />
      ) : null}
      {stderr && stderr.length > 0 ? (
        <AnsiOutput
          text={stderr}
          tone="error"
          maxLines={10}
          stateKey={`block:${block.key}:stderr`}
          streaming={block.streaming}
        />
      ) : null}
      {!body && !stderr && block.status !== "running" && output.length > 0 ? (
        <AnsiOutput
          text={output}
          tone={block.status === "error" ? "error" : "default"}
          stateKey={`block:${block.key}:output`}
          streaming={block.streaming}
        />
      ) : null}
    </div>
  );
}

/**
 * The card already knows the absolute path and the bridge already opens files in
 * a preview panel; without this the reader has to retype the path by hand.
 */
function OpenFile({ path }: { path: string | undefined }) {
  const copy = useCopy();
  if (!path) return null;
  // The card head already prints the path, so this row is the action alone.
  return (
    <div className="tool-file-row">
      <button
        type="button"
        className="link-btn"
        title={path}
        onClick={() => void getBridge().openFile({ path }).catch(() => undefined)}
      >
        {copy("supermux.harness.tool.openFile")}
      </button>
    </div>
  );
}

export function EditBody({ block }: { block: ToolBlock }) {
  const path = str(block.input.file_path) ?? str(block.structured?.filePath);
  const hunks = patchOf(block.structured);
  const language = languageForPath(path);
  if (hunks.length === 0) {
    const oldText = str(block.input.old_string);
    const newText = str(block.input.new_string);
    if (oldText || newText) {
      return (
        <div className="tool-body">
          {oldText ? (
            <CodeBlock
              code={oldText}
              language={language}
              dense
              maxLines={8}
              stateKey={`block:${block.key}:old`}
            />
          ) : null}
          {newText ? (
            <CodeBlock
              code={newText}
              language={language}
              dense
              maxLines={8}
              stateKey={`block:${block.key}:new`}
            />
          ) : null}
          <ErrorText block={block} />
          <OpenFile path={path} />
        </div>
      );
    }
    return <ResultFallback block={block} />;
  }
  return (
    <div className="tool-body">
      <DiffView hunks={hunks} language={language} stateKey={`block:${block.key}:diff`} />
      <ErrorText block={block} />
      <OpenFile path={path} />
    </div>
  );
}

export function WriteBody({ block }: { block: ToolBlock }) {
  const path = str(block.input.file_path) ?? str(block.structured?.filePath);
  const hunks = patchOf(block.structured);
  const language = languageForPath(path);
  if (hunks.length > 0) {
    return (
      <div className="tool-body">
        <DiffView hunks={hunks} language={language} stateKey={`block:${block.key}:diff`} />
        <ErrorText block={block} />
        <OpenFile path={path} />
      </div>
    );
  }
  const content = str(block.input.content) ?? str(block.structured?.content);
  if (!content) return <ResultFallback block={block} />;
  return (
    <div className="tool-body">
      <CodeBlock
        code={content}
        language={language}
        filename={path ? shortenPath(path, 2) : undefined}
        maxLines={18}
        stateKey={`block:${block.key}:content`}
      />
      <ErrorText block={block} />
      <OpenFile path={path} />
    </div>
  );
}

export function ReadBody({ block }: { block: ToolBlock }) {
  const file = block.structured?.file as JsonObject | undefined;
  const path = str(block.input.file_path) ?? str(file?.filePath);
  const content = str(file?.content);
  if (!content) return <ResultFallback block={block} />;
  return (
    <div className="tool-body">
      <CodeBlock
        code={content}
        language={languageForPath(path)}
        filename={path ? shortenPath(path, 2) : undefined}
        maxLines={16}
        stateKey={`block:${block.key}:content`}
      />
      <ErrorText block={block} />
      <OpenFile path={path} />
    </div>
  );
}

export function SearchBody({ block }: { block: ToolBlock }) {
  const filenames = block.structured?.filenames;
  if (Array.isArray(filenames) && filenames.length > 0) {
    return (
      <div className="tool-body">
        <ul className="result-list">
          {(filenames as string[]).slice(0, 40).map((file) => (
            <li key={file} className="mono">
              {shortenPath(file, 4)}
            </li>
          ))}
        </ul>
        <ErrorText block={block} />
      </div>
    );
  }
  return <ResultFallback block={block} />;
}

export function WebBody({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const results = block.structured?.results;
  if (Array.isArray(results) && results.length > 0) {
    return (
      <div className="tool-body">
        <ul className="web-list">
          {(results as Array<{ title?: string; url?: string }>).slice(0, 10).map((result, i) => (
            <li key={i}>
              <span className="web-title">
                {result.title ?? result.url ?? copy("supermux.harness.tool.webResult")}
              </span>
              {result.url ? <span className="web-url mono">{result.url}</span> : null}
            </li>
          ))}
        </ul>
        <ErrorText block={block} />
      </div>
    );
  }
  const text = block.resultText;
  if (!text) return null;
  // A fetch failure is a terse machine string, not prose: markdown would swallow
  // its leading token and it belongs in the error tone like every other failure.
  if (block.status === "error") return <ResultFallback block={block} />;
  return (
    <div className="tool-body">
      <Markdown text={text.slice(0, 4000)} stateKey={`block:${block.key}:web`} />
    </div>
  );
}

export function TodoBody({ block }: { block: ToolBlock }) {
  const raw = (block.structured?.newTodos ?? block.input.todos) as unknown;
  if (!Array.isArray(raw)) return <ResultFallback block={block} />;
  const todos = raw as Array<{ content?: string; status?: string }>;
  return (
    <div className="tool-body">
      <ul className="todo-list">
        {todos.map((todo, i) => (
          <li key={i} className={`todo-item is-${todo.status ?? "pending"}`}>
            <span className="todo-mark" aria-hidden="true">
              {todo.status === "completed" ? "✓" : todo.status === "in_progress" ? "●" : "○"}
            </span>
            <span className="todo-text">{todo.content}</span>
          </li>
        ))}
      </ul>
      <ErrorText block={block} />
    </div>
  );
}

export function InteractiveBody({ block }: { block: ToolBlock }) {
  const plan = str(block.input.plan) ?? str(block.input.get_plan);
  if (plan) {
    return (
      <div className="tool-body">
        <Markdown text={plan} stateKey={`block:${block.key}:plan`} />
        <ErrorText block={block} />
      </div>
    );
  }
  const questions = block.input.questions ?? block.structured?.questions;
  if (Array.isArray(questions)) {
    // Where the answers actually are depends on how the card reached the
    // screen. A question with NO streamed tool_use block is materialised by the
    // reducer from the control response, with the answers folded into `input`.
    // But when the CLI DID stream an assistant tool_use frame — every recent
    // trace does — the block's input is the original questions alone, and the
    // answers arrive on the `tool_use_result` of the settling user frame
    // (`toolUseResult.answers` on disk, the same object live), which lands in
    // `structured`. Reading only `input.answers` is the round-6 screenshot:
    // "Asked you a question" expanded to three em-dashes over answers the agent
    // had plainly received. Both sources are consulted; input wins because it
    // is what THIS user submitted, and structured is the CLI's record of it.
    const answers = (block.input.answers ??
      block.structured?.answers ??
      {}) as Record<string, unknown>;
    return (
      <div className="tool-body">
        <dl className="qa-list">
          {(questions as Array<{ question?: string; header?: string }>).map((q, i) => {
            const answer = q.question ? str(answers[q.question]) : undefined;
            return (
              <div key={i} className="qa-row">
                <dt className="qa-question">{q.header ? `${q.header} · ` : ""}{q.question}</dt>
                <dd className={`qa-answer${answer ? "" : " is-unanswered"}`}>
                  {answer ?? "—"}
                </dd>
              </div>
            );
          })}
        </dl>
        <ErrorText block={block} />
      </div>
    );
  }
  return <ResultFallback block={block} />;
}

export function McpBody({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const server = mcpServerName(block.name);
  const input = JSON.stringify(block.input, null, 2);
  const output = block.resultText;
  return (
    <div className="tool-body">
      {server ? <div className="mcp-server">{copy("supermux.harness.tool.mcpServer", { server })}</div> : null}
      {input !== "{}" ? (
        <CodeBlock
          code={input}
          language="json"
          dense
          maxLines={12}
          stateKey={`block:${block.key}:input`}
        />
      ) : null}
      {output ? (
        <AnsiOutput
          text={output}
          maxLines={14}
          tone={block.status === "error" ? "error" : "default"}
          stateKey={`block:${block.key}:output`}
        />
      ) : null}
    </div>
  );
}

export function GenericBody({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const input = JSON.stringify(block.input, null, 2);
  const output = block.resultText;
  // The fallback renderer knows nothing about the tool, so the one thing it can
  // still do for a reader is say which half of the dump is which.
  return (
    <div className="tool-body">
      {input !== "{}" ? (
        <>
          <div className="tool-section-label">{copy("supermux.harness.tool.rawInput")}</div>
          <CodeBlock
            code={input}
            language="json"
            dense
            maxLines={12}
            stateKey={`block:${block.key}:input`}
          />
        </>
      ) : null}
      {output ? (
        <>
          <div className="tool-section-label">{copy("supermux.harness.tool.rawOutput")}</div>
          <AnsiOutput
            text={output}
            maxLines={14}
            tone={block.status === "error" ? "error" : "default"}
            stateKey={`block:${block.key}:output`}
          />
        </>
      ) : null}
      {input === "{}" && !output ? (
        <div className="tool-waiting mono">{copy("supermux.harness.tool.noOutput")}</div>
      ) : null}
    </div>
  );
}

export function toolMetrics(block: ToolBlock, copy: CopyFn): string[] {
  const out: string[] = [];
  const structured = block.structured;
  if (!structured) return out;
  const file = structured.file as JsonObject | undefined;
  const totalLines = num(file?.totalLines) ?? num(structured.numLines);
  if (totalLines !== undefined) {
    out.push(
      plural(copy, totalLines, "supermux.harness.tool.linesReadOne", "supermux.harness.tool.linesRead")
    );
  }
  const numFiles = num(structured.numFiles);
  if (numFiles !== undefined) {
    out.push(
      plural(copy, numFiles, "supermux.harness.tool.filesFoundOne", "supermux.harness.tool.filesFound")
    );
  }
  // `numMatches` counts what a search FOUND; `total_deferred_tools` counts the
  // catalogue it searched. Folding the second into the first is how a
  // zero-match ToolSearch came to advertise "19 matches" beside a body reading
  // "No matching deferred tools found".
  const numMatches = num(structured.numMatches) ?? countOf(structured.matches);
  if (numMatches !== undefined) {
    out.push(
      plural(copy, numMatches, "supermux.harness.tool.matchesFoundOne", "supermux.harness.tool.matchesFound")
    );
  }
  const searched = num(structured.total_deferred_tools);
  if (searched !== undefined) {
    out.push(
      plural(copy, searched, "supermux.harness.tool.toolsSearchedOne", "supermux.harness.tool.toolsSearched")
    );
  }
  const results = countOf(structured.results);
  if (results !== undefined) {
    out.push(
      plural(
        copy,
        results,
        "supermux.harness.tool.searchResultsOne",
        "supermux.harness.tool.searchResults"
      )
    );
  }
  const duration = num(structured.durationMs);
  if (duration !== undefined) {
    out.push(copy("supermux.harness.tool.durationMs", { count: duration }));
  }
  return out;
}

function countOf(value: unknown): number | undefined {
  return Array.isArray(value) ? value.length : undefined;
}
