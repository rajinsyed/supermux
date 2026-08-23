import {
  memo,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useSyncExternalStore
} from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import type { Code, Nodes, Parents, Root } from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";
import { plural, useCopy } from "../CopyContext";
import { usePresentationState } from "../presentationState";
import { clipUtf8, lineCount } from "../utf8";
import { CodeBlock } from "./CodeBlock";

interface MarkdownProps {
  text: string;
  streaming?: boolean;
  /** Conversation generation disambiguating reused wire block identities. */
  streamGeneration?: number;
  /**
   * Stable across reducer-proven append deltas and advanced by authoritative
   * replacements. Production text blocks always supply it; generic callers fall
   * back to an exact prefix check.
   */
  streamEpoch?: number;
  className?: string;
  /** Optional preview cap; the complete value remains available on demand. */
  maxBytes?: number;
  /** Stable transcript identity used to restore reader state after unmount. */
  stateKey?: string;
}

const ALLOWED_PROTOCOL = /^(https?:|mailto:|#|\/)/i;
const REMARK_PLUGINS = [remarkGfm];
const STREAM_PARSER = unified().use(remarkParse).use(remarkGfm);

type Listener = () => void;

interface MutableCodeSnapshot {
  revision: number;
  code: string;
}

class MutableFenceStore {
  private snapshot: MutableCodeSnapshot;
  private pendingCode: string;
  private dirty = false;
  private listeners = new Set<Listener>();

  constructor(code: string) {
    this.snapshot = { revision: 0, code };
    this.pendingCode = code;
  }

  getSnapshot = (): MutableCodeSnapshot => this.snapshot;

  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  update(code: string): void {
    this.pendingCode = code;
    this.dirty = true;
  }

  publish(): void {
    if (!this.dirty) return;
    this.dirty = false;
    this.snapshot = {
      revision: this.snapshot.revision + 1,
      code: this.pendingCode
    };
    for (const listener of this.listeners) listener();
  }
}

interface MutableFenceSource {
  start: number;
  store: MutableFenceStore;
}

let validationCodeUnits = 0;
let scannerCodeUnits = 0;
let explicitParserInputCodeUnits = 0;
let renderedParserInputCodeUnits = 0;

export interface StreamingMarkdownDiagnostics {
  /** Exact fallback prefix validation; zero on the reducer-proven production path. */
  validationCodeUnits: number;
  /** Source units consumed by the incremental open-fence scanner. */
  scannerCodeUnits: number;
  /** Backward-compatible name retained for the first no-rescan regression. */
  scannedCodeUnits: number;
  /** Input sent to the parser for stream analysis and open/closed oracles. */
  explicitParserInputCodeUnits: number;
  /** Input actually rendered through ReactMarkdown. */
  renderedParserInputCodeUnits: number;
  parserInputCodeUnits: number;
  totalCodeUnits: number;
}

export function streamingMarkdownDiagnostics(): StreamingMarkdownDiagnostics {
  const parserInputCodeUnits = explicitParserInputCodeUnits + renderedParserInputCodeUnits;
  return {
    validationCodeUnits,
    scannerCodeUnits,
    scannedCodeUnits: scannerCodeUnits,
    explicitParserInputCodeUnits,
    renderedParserInputCodeUnits,
    parserInputCodeUnits,
    totalCodeUnits: validationCodeUnits + scannerCodeUnits + parserInputCodeUnits
  };
}

export function resetStreamingMarkdownDiagnostics(): void {
  validationCodeUnits = 0;
  scannerCodeUnits = 0;
  explicitParserInputCodeUnits = 0;
  renderedParserInputCodeUnits = 0;
}

function safeHref(href: string | undefined): string | undefined {
  if (!href) return undefined;
  return ALLOWED_PROTOCOL.test(href.trim()) ? href : undefined;
}

export const Markdown = memo(function Markdown({
  text,
  streaming = false,
  streamGeneration,
  streamEpoch,
  className,
  maxBytes,
  stateKey
}: MarkdownProps) {
  const copy = useCopy();
  const localId = useId();
  const rootKey = stateKey ?? `markdown:${localId}`;
  const [expanded, setExpanded] = usePresentationState(`${rootKey}:expanded`, false);
  const preview = useMemo(
    () => (maxBytes === undefined ? { text, truncated: false } : clipUtf8(text, maxBytes)),
    [maxBytes, text]
  );
  const visible = expanded || !preview.truncated ? text : preview.text;

  return (
    <div className={`md${className ? ` ${className}` : ""}`}>
      {streaming ? (
        <StreamingMarkdownContent
          text={visible}
          stateKey={rootKey}
          streamGeneration={streamGeneration}
          streamEpoch={streamEpoch}
        />
      ) : (
        <MarkdownContent text={visible} stateKey={rootKey} sourceOffset={0} />
      )}
      {preview.truncated ? (
        <button type="button" className="code-block-more" onClick={() => setExpanded((value) => !value)}>
          {expanded
            ? copy("supermux.harness.tool.showLess")
            : plural(
                copy,
                Math.max(1, lineCount(text) - lineCount(preview.text)),
                "supermux.harness.tool.showMoreOne",
                "supermux.harness.tool.showMore"
              )}
        </button>
      ) : null}
    </div>
  );
});

function MutableFenceCode({
  store,
  language,
  stateKey
}: {
  store: MutableFenceStore;
  language?: string;
  stateKey: string;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  return <CodeBlock code={snapshot.code} language={language} streaming stateKey={stateKey} />;
}

const MarkdownContent = memo(function MarkdownContent({
  text,
  stateKey,
  sourceOffset,
  streaming = false,
  mutableFence
}: {
  text: string;
  stateKey: string;
  sourceOffset: number;
  streaming?: boolean;
  mutableFence?: MutableFenceSource;
}) {
  const copy = useCopy();
  renderedParserInputCodeUnits += text.length;
  const components = useMemo<Components>(
    () => ({
      a({ href, children }) {
        const safe = safeHref(href);
        if (!safe) return <span>{children}</span>;
        return (
          <a href={safe} target="_blank" rel="noreferrer noopener">
            {children}
          </a>
        );
      },
      code({ className: codeClass, children, node }) {
        const localOffset = node?.position?.start.offset ?? 0;
        const absoluteOffset = sourceOffset + localOffset;
        const language = /language-(\w[\w+-]*)/.exec(codeClass ?? "")?.[1];
        if (mutableFence && mutableFence.start === absoluteOffset) {
          return (
            <MutableFenceCode
              store={mutableFence.store}
              language={language}
              stateKey={`${stateKey}:fence:${absoluteOffset}`}
            />
          );
        }
        const raw = String(children ?? "");
        if (!language && !raw.includes("\n")) {
          return <code className="inline-code">{raw.replace(/\n$/, "")}</code>;
        }
        return (
          <CodeBlock
            code={raw}
            language={language}
            streaming={streaming}
            stateKey={`${stateKey}:fence:${absoluteOffset}`}
          />
        );
      },
      pre({ children }) {
        return <>{children}</>;
      },
      table({ children }) {
        return (
          <div className="md-table-wrap">
            <table>{children}</table>
          </div>
        );
      },
      img({ alt }) {
        return (
          <span className="md-image-placeholder">
            {alt || copy("supermux.harness.composer.attachmentName")}
          </span>
        );
      }
    }),
    [copy, mutableFence, sourceOffset, stateKey, streaming]
  );

  return (
    <ReactMarkdown remarkPlugins={REMARK_PLUGINS} components={components} skipHtml>
      {text}
    </ReactMarkdown>
  );
});

interface StreamChunk {
  start: number;
  text: string;
}

type FenceContainer =
  | { kind: "blockquote" }
  | { kind: "list"; continuationColumns: number };

interface FenceContext {
  /** Parser ancestry order, including interleaved list and blockquote layers. */
  containers: FenceContainer[];
  /** CommonMark removes up to this many columns from each code content line. */
  openingIndent: number;
}

type FenceLinePhase =
  | { kind: "container"; index: number; column: number }
  | { kind: "quoteIndent"; index: number; column: number; indentColumns: number }
  | { kind: "quoteSpace"; index: number; column: number }
  | {
      kind: "listIndent";
      index: number;
      column: number;
      consumedColumns: number;
    }
  | {
      kind: "leading";
      whitespace: string[];
      columns: number;
      startColumn: number;
      column: number;
    }
  | {
      kind: "candidate";
      leadingWhitespace: string[];
      leadingColumns: number;
      leadingStartColumn: number;
      markerCount: number;
      trailingWhitespace: string[];
      sawTrailingWhitespace: boolean;
      column: number;
    }
  | { kind: "content"; column: number }
  | { kind: "outside" };

interface FenceLineState {
  phase: FenceLinePhase;
  /** Expanded tab columns still available to later container/indent phases. */
  pendingColumns: number;
}

const PENDING_OPENER_CHUNK_SIZE = 64;

interface PendingOpener {
  start: number;
  prefixSource: string;
  rawChunks: string[];
  rawLength: number;
  marker: "`" | "~";
  markerOffset: number;
  markerCount: number;
  phase: "delimiter" | "info";
  infoValid: boolean;
}

interface OpenFence {
  start: number;
  /** Stable parser input through the opener; never sliced or compared per delta. */
  renderSource: string;
  marker: "`" | "~";
  markerLength: number;
  context: FenceContext;
  codeText: string;
  line: FenceLineState;
  /** A CR completed a line; a following LF extends that exact source ending. */
  pendingLfKind?: "opener" | "code";
  /** The current unterminated line is a valid closer at EOF. */
  eofClosed: boolean;
  source: MutableFenceSource;
}

interface StreamAccumulator {
  fullText: string;
  sourceLength: number;
  provenanceGeneration?: number;
  provenanceEpoch?: number;
  committedLength: number;
  chunks: StreamChunk[];
  pendingOpener?: PendingOpener;
  openFence?: OpenFence;
}

interface CodeCandidate {
  node: Code;
  ancestors: Nodes[];
}

interface SourceUpdate {
  state: StreamAccumulator;
  delta: string;
}

function freshStream(): StreamAccumulator {
  return {
    fullText: "",
    sourceLength: 0,
    committedLength: 0,
    chunks: []
  };
}

function StreamingMarkdownContent({
  text,
  stateKey,
  streamGeneration,
  streamEpoch
}: {
  text: string;
  stateKey: string;
  streamGeneration?: number;
  streamEpoch?: number;
}) {
  const accumulator = useRef<StreamAccumulator>(freshStream());
  const view = advanceStream(accumulator.current, text, streamGeneration, streamEpoch);
  accumulator.current = view;
  const openFence = view.openFence;
  const pendingOpener = view.pendingOpener;
  useLayoutEffect(() => {
    openFence?.source.store.publish();
  }, [openFence, view.sourceLength]);
  const tail = openFence || pendingOpener
    ? undefined
    : view.fullText.slice(view.committedLength);

  return (
    <>
      {view.chunks.map((chunk) => (
        <MarkdownContent
          key={chunk.start}
          text={chunk.text}
          stateKey={stateKey}
          sourceOffset={chunk.start}
        />
      ))}
      {openFence ? (
        <MarkdownContent
          text={openFence.renderSource}
          stateKey={stateKey}
          sourceOffset={view.committedLength}
          streaming
          mutableFence={openFence.source}
        />
      ) : pendingOpener ? (
        <>
          {pendingOpener.prefixSource ? (
            <MarkdownContent
              text={pendingOpener.prefixSource}
              stateKey={stateKey}
              sourceOffset={view.committedLength}
              streaming
            />
          ) : null}
          <pre className="md-pending-opener">
            <code>
              {pendingOpener.rawChunks.map((chunk, index) => (
                <span key={index}>{chunk}</span>
              ))}
            </code>
          </pre>
        </>
      ) : tail ? (
        <MarkdownContent
          text={tail}
          stateKey={stateKey}
          sourceOffset={view.committedLength}
          streaming
        />
      ) : null}
    </>
  );
}

function advanceStream(
  previous: StreamAccumulator,
  text: string,
  streamGeneration: number | undefined,
  streamEpoch: number | undefined
): StreamAccumulator {
  const update = applySourceUpdate(previous, text, streamGeneration, streamEpoch);
  const state = update.state;
  if (update.delta.length === 0) return state;

  if (state.pendingOpener) {
    const result = appendToPendingOpener(state.pendingOpener, update.delta);
    if (result === "pending") return state;
    state.pendingOpener = undefined;
  }

  if (state.openFence) {
    const result = appendToOpenFence(state.openFence, update.delta);
    if (result === "open") return state;
    state.openFence = undefined;
  }

  const tail = text.slice(state.committedLength);
  const tree = parseStreamSource(tail);
  const openFence = findOpenFence(tree, tail, state.committedLength);
  if (openFence) {
    state.openFence = openFence;
    return state;
  }
  const pendingOpener = findPendingOpener(tree, tail, state.committedLength);
  if (pendingOpener) {
    state.pendingOpener = pendingOpener;
    return state;
  }

  const relativeBoundary = parserProvenSafeBoundary(tree, tail);
  if (relativeBoundary > 0) {
    const boundary = state.committedLength + relativeBoundary;
    state.chunks.push({
      start: state.committedLength,
      text: text.slice(state.committedLength, boundary)
    });
    state.committedLength = boundary;
  }
  return state;
}

function resetStream(
  text: string,
  provenance?: { generation: number; epoch: number }
): SourceUpdate {
  const state = freshStream();
  state.fullText = text;
  state.sourceLength = text.length;
  if (provenance) {
    state.provenanceGeneration = provenance.generation;
    state.provenanceEpoch = provenance.epoch;
  }
  return { state, delta: text };
}

function applySourceUpdate(
  state: StreamAccumulator,
  text: string,
  streamGeneration: number | undefined,
  streamEpoch: number | undefined
): SourceUpdate {
  if (streamEpoch !== undefined) {
    const generation = streamGeneration ?? 0;
    const reset =
      state.provenanceGeneration !== generation ||
      state.provenanceEpoch !== streamEpoch ||
      text.length < state.sourceLength;
    if (reset) return resetStream(text, { generation, epoch: streamEpoch });

    const delta = text.slice(state.sourceLength);
    state.fullText = text;
    state.sourceLength = text.length;
    return { state, delta };
  }

  const previous = state.fullText;
  if (previous.length === 0) return resetStream(text);
  let append = text.length >= previous.length;
  if (append) {
    for (let index = 0; index < previous.length; index += 1) {
      validationCodeUnits += 1;
      if (text.charCodeAt(index) !== previous.charCodeAt(index)) {
        append = false;
        break;
      }
    }
  }
  if (!append) return resetStream(text);

  const delta = text.slice(previous.length);
  state.fullText = text;
  state.sourceLength = text.length;
  return { state, delta };
}

function parseStreamSource(text: string): Root {
  explicitParserInputCodeUnits += text.length;
  return STREAM_PARSER.parse(text);
}

function hasChildren(node: Nodes): node is Parents {
  return "children" in node;
}

function codeCandidates(node: Nodes, ancestors: Nodes[] = [], found: CodeCandidate[] = []): CodeCandidate[] {
  if (node.type === "code") found.push({ node, ancestors });
  if (hasChildren(node)) {
    const nextAncestors = ancestors.concat(node);
    for (const child of node.children) codeCandidates(child, nextAncestors, found);
  }
  return found;
}

function findPendingOpener(
  tree: Root,
  text: string,
  sourceOffset: number
): PendingOpener | undefined {
  if (endsWithLineBreak(text)) return undefined;
  const candidates = codeCandidates(tree).reverse();
  for (const candidate of candidates) {
    const start = candidate.node.position?.start.offset;
    const end = candidate.node.position?.end.offset;
    if (start === undefined || end === undefined || !candidateReachesSourceEnd(text, end)) continue;
    const marker = text[start];
    if (marker !== "`" && marker !== "~") continue;
    const lineStart = physicalLineStart(text, start);
    if (physicalLineEnd(text, start) !== text.length) continue;
    const rawLine = text.slice(lineStart);
    const markerOffset = start - lineStart;
    const pending: PendingOpener = {
      start: sourceOffset + lineStart,
      prefixSource: text.slice(0, lineStart),
      rawChunks: [],
      rawLength: 0,
      marker,
      markerOffset,
      markerCount: 0,
      phase: "delimiter",
      infoValid: true
    };
    scanPendingOpener(pending, rawLine);
    if (pending.markerCount >= 3) return pending;
  }
  return undefined;
}

function appendPendingOpenerCharacter(pending: PendingOpener, character: string): number {
  const offset = pending.rawLength;
  const tailIndex = pending.rawChunks.length - 1;
  if (
    tailIndex < 0 ||
    pending.rawChunks[tailIndex].length >= PENDING_OPENER_CHUNK_SIZE
  ) {
    pending.rawChunks.push(character);
  } else {
    pending.rawChunks[tailIndex] += character;
  }
  pending.rawLength += 1;
  return offset;
}

function scanPendingOpener(pending: PendingOpener, source: string): void {
  for (const character of source) {
    scannerCodeUnits += 1;
    const offset = appendPendingOpenerCharacter(pending, character);
    if (offset < pending.markerOffset) continue;
    if (pending.phase === "delimiter" && character === pending.marker) {
      pending.markerCount += 1;
      continue;
    }
    pending.phase = "info";
    if (pending.marker === "`" && character === "`") pending.infoValid = false;
  }
}

function appendToPendingOpener(
  pending: PendingOpener,
  delta: string
): "pending" | "terminated" {
  for (const character of delta) {
    scannerCodeUnits += 1;
    if (character === "\r" || character === "\n") return "terminated";
    const offset = appendPendingOpenerCharacter(pending, character);
    if (offset < pending.markerOffset) continue;
    if (pending.phase === "delimiter" && character === pending.marker) {
      pending.markerCount += 1;
      continue;
    }
    pending.phase = "info";
    if (pending.marker === "`" && character === "`") pending.infoValid = false;
  }
  return "pending";
}

function findOpenFence(tree: Root, text: string, sourceOffset: number): OpenFence | undefined {
  const candidates = codeCandidates(tree).reverse();
  for (const candidate of candidates) {
    const start = candidate.node.position?.start.offset;
    const end = candidate.node.position?.end.offset;
    if (start === undefined || end === undefined || !candidateReachesSourceEnd(text, end)) continue;

    const marker = text[start];
    if (marker !== "`" && marker !== "~") continue;
    let markerEnd = start;
    while (text[markerEnd] === marker) markerEnd += 1;
    const markerLength = markerEnd - start;
    if (markerLength < 3) continue;

    const openerLineStart = physicalLineStart(text, start);
    const contentStart = physicalLineEnd(text, start);
    // The parser accepts a delimiter at EOF as an empty fenced block, but the
    // physical opener is still mutable until its line ending arrives: more
    // markers, info text, or an invalid backtick can all change its meaning.
    if (contentStart === text.length && !endsWithLineBreak(text)) continue;
    const context = deriveFenceContext(candidate, text, openerLineStart, start);
    if (!context) continue;

    const completedLine = completedLineBeforeEof(text, contentStart);
    if (completedLine) {
      const completedState = fenceLineStateForRange(
        text,
        completedLine.start,
        completedLine.end,
        context,
        marker
      );
      if (isCompleteCloser(completedState, markerLength)) continue;
    }

    const currentLineStart = endsWithLineBreak(text)
      ? text.length
      : Math.max(contentStart, physicalLineStart(text, text.length));
    const line = fenceLineStateForRange(text, currentLineStart, text.length, context, marker);
    if (line.phase.kind === "outside") continue;

    const eofClosed = isCompleteCloser(line, markerLength);
    let codeText = candidate.node.value;
    if (!eofClosed) {
      const held = pendingFenceLineText(line, context, marker);
      if (held.length > 0 && codeText.endsWith(held)) {
        scannerCodeUnits += held.length;
        codeText = codeText.slice(0, -held.length);
      }
    } else if (currentLineStart > contentStart && !endsWithLineBreak(codeText)) {
      // A parser-recognized EOF closer is excluded from `node.value`, including
      // the line separator before it. If later prose invalidates that closer,
      // the held marker line must re-enter code after the original separator.
      codeText += lineEndingBefore(text, currentLineStart);
    }

    let pendingLfKind: OpenFence["pendingLfKind"];
    if (text.length > contentStart && endsWithLineBreak(text)) {
      if (text.endsWith("\r\n")) codeText += "\r\n";
      else if (text.endsWith("\r")) {
        codeText += "\r";
        pendingLfKind = "code";
      } else codeText += "\n";
    } else if (contentStart === text.length && text.endsWith("\r")) {
      pendingLfKind = "opener";
    }

    const store = new MutableFenceStore(codeText);
    return {
      start: sourceOffset + start,
      renderSource: text.slice(0, contentStart),
      marker,
      markerLength,
      context,
      codeText,
      line,
      pendingLfKind,
      eofClosed,
      source: { start: sourceOffset + start, store }
    };
  }
  return undefined;
}

function candidateReachesSourceEnd(text: string, end: number): boolean {
  if (end === text.length) return true;
  if (end + 1 === text.length) return text[end] === "\n" || text[end] === "\r";
  return end + 2 === text.length && text[end] === "\r" && text[end + 1] === "\n";
}

interface SourceCursor {
  index: number;
  /** Physical column after every consumed source character. */
  column: number;
  /** Expanded tab columns not yet claimed by a container or opener indent. */
  pendingColumns: number;
}

interface ContainerDescriptor {
  container: FenceContainer;
  startOffset: number;
  startLine: number;
}

function deriveFenceContext(
  candidate: CodeCandidate,
  text: string,
  lineStart: number,
  start: number
): FenceContext | undefined {
  const descriptors: ContainerDescriptor[] = [];
  for (const ancestor of candidate.ancestors) {
    if (ancestor.type !== "blockquote" && ancestor.type !== "listItem") continue;
    const position = ancestor.position?.start;
    if (position?.offset === undefined) return undefined;
    if (ancestor.type === "blockquote") {
      descriptors.push({
        container: { kind: "blockquote" },
        startOffset: position.offset,
        startLine: position.line
      });
      continue;
    }

    const continuationColumns = deriveListContinuationColumns(
      text,
      descriptors,
      position.offset,
      position.line
    );
    if (continuationColumns === undefined) return undefined;
    descriptors.push({
      container: { kind: "list", continuationColumns },
      startOffset: position.offset,
      startLine: position.line
    });
  }

  const openerLine = candidate.node.position?.start.line;
  if (openerLine === undefined) return undefined;
  let cursor: SourceCursor | undefined = { index: lineStart, column: 0, pendingColumns: 0 };
  for (const descriptor of descriptors) {
    cursor = consumeContainerSource(text, cursor, start, openerLine, descriptor);
    if (!cursor) return undefined;
  }
  const beforeOpeningIndent = cursor.column - cursor.pendingColumns;
  cursor = consumeWhitespaceToOffset(text, cursor, start);
  if (!cursor) return undefined;
  const openingIndent = cursor.column - beforeOpeningIndent;
  if (openingIndent < 0 || openingIndent > 3) return undefined;
  return {
    containers: descriptors.map((descriptor) => descriptor.container),
    openingIndent
  };
}

function deriveListContinuationColumns(
  text: string,
  parents: ContainerDescriptor[],
  startOffset: number,
  startLine: number
): number | undefined {
  const lineStart = physicalLineStart(text, startOffset);
  let cursor: SourceCursor | undefined = { index: lineStart, column: 0, pendingColumns: 0 };
  for (const descriptor of parents) {
    cursor = consumeContainerSource(text, cursor, startOffset, startLine, descriptor);
    if (!cursor) return undefined;
  }
  const beforeGap = cursor.column - cursor.pendingColumns;
  cursor = consumeWhitespaceToOffset(text, cursor, startOffset);
  if (!cursor) return undefined;
  const gapColumns = cursor.column - beforeGap;
  const marker = consumeListMarkerSource(text, cursor, physicalLineEnd(text, startOffset));
  if (!marker) return undefined;
  return gapColumns + marker.continuationColumns;
}

function consumeContainerSource(
  text: string,
  cursor: SourceCursor,
  limit: number,
  line: number,
  descriptor: ContainerDescriptor
): SourceCursor | undefined {
  if (descriptor.container.kind === "blockquote") {
    return consumeQuoteSource(text, cursor, limit);
  }
  if (descriptor.startLine === line) {
    const atMarker = consumeWhitespaceToOffset(text, cursor, descriptor.startOffset);
    if (!atMarker) return undefined;
    return consumeListMarkerSource(text, atMarker, limit)?.cursor;
  }
  return consumeWhitespaceColumns(
    text,
    cursor,
    limit,
    descriptor.container.continuationColumns
  );
}

function consumeQuoteSource(
  text: string,
  cursor: SourceCursor,
  limit: number
): SourceCursor | undefined {
  let { index, column, pendingColumns } = cursor;
  let indentColumns = pendingColumns;
  if (indentColumns > 3) return undefined;
  pendingColumns = 0;
  while (index < limit && isMarkdownWhitespace(text[index])) {
    const width = whitespaceWidth(text[index], column);
    if (indentColumns + width > 3) break;
    indentColumns += width;
    column += width;
    index += 1;
  }
  if (index >= limit || text[index] !== ">") return undefined;
  index += 1;
  column += 1;
  if (index < limit && isMarkdownWhitespace(text[index])) {
    const width = whitespaceWidth(text[index], column);
    column += width;
    pendingColumns += Math.max(0, width - 1);
    index += 1;
  }
  return { index, column, pendingColumns };
}

function consumeListMarkerSource(
  text: string,
  cursor: SourceCursor,
  limit: number
): { cursor: SourceCursor; continuationColumns: number } | undefined {
  const startColumn = cursor.column;
  let { index, column } = cursor;
  const first = text[index];
  if (first === "-" || first === "+" || first === "*") {
    index += 1;
    column += 1;
  } else {
    let digits = 0;
    while (index < limit && digits < 9 && text[index] >= "0" && text[index] <= "9") {
      index += 1;
      column += 1;
      digits += 1;
    }
    if (digits === 0 || (text[index] !== "." && text[index] !== ")")) return undefined;
    index += 1;
    column += 1;
  }

  const markerColumns = column - startColumn;
  const whitespaceStart = index;
  const whitespaceColumn = column;
  while (index < limit && isMarkdownWhitespace(text[index])) {
    column += whitespaceWidth(text[index], column);
    index += 1;
  }
  const whitespaceColumns = column - whitespaceColumn;
  if (whitespaceColumns === 0) {
    if (text[index] !== "\r" && text[index] !== "\n") return undefined;
    return {
      cursor: { index: whitespaceStart, column: whitespaceColumn, pendingColumns: 0 },
      continuationColumns: markerColumns + 1
    };
  }
  if (whitespaceColumns <= 4) {
    return {
      cursor: { index, column, pendingColumns: 0 },
      continuationColumns: markerColumns + whitespaceColumns
    };
  }
  if (text[whitespaceStart] !== " ") return undefined;
  return {
    cursor: {
      index: whitespaceStart + 1,
      column: whitespaceColumn + 1,
      pendingColumns: 0
    },
    continuationColumns: markerColumns + 1
  };
}

function consumeWhitespaceToOffset(
  text: string,
  cursor: SourceCursor,
  target: number
): SourceCursor | undefined {
  let { index, column } = cursor;
  while (index < target) {
    if (!isMarkdownWhitespace(text[index])) return undefined;
    column += whitespaceWidth(text[index], column);
    index += 1;
  }
  return index === target ? { index, column, pendingColumns: 0 } : undefined;
}

function consumeWhitespaceColumns(
  text: string,
  cursor: SourceCursor,
  limit: number,
  targetColumns: number
): SourceCursor | undefined {
  let { index, column, pendingColumns } = cursor;
  let consumedColumns = Math.min(pendingColumns, targetColumns);
  pendingColumns -= consumedColumns;
  while (consumedColumns < targetColumns && index < limit) {
    const character = text[index];
    if (!isMarkdownWhitespace(character)) return undefined;
    const width = whitespaceWidth(character, column);
    index += 1;
    column += width;
    const remaining = targetColumns - consumedColumns;
    if (width > remaining) {
      pendingColumns += width - remaining;
      consumedColumns = targetColumns;
      break;
    }
    consumedColumns += width;
  }
  return consumedColumns === targetColumns
    ? { index, column, pendingColumns }
    : undefined;
}

function isMarkdownWhitespace(character: string): boolean {
  return character === " " || character === "\t";
}

function whitespaceWidth(character: string, column: number): number {
  return character === "\t" ? 4 - (column % 4) : 1;
}

function completedLineBeforeEof(
  text: string,
  contentStart: number
): { start: number; end: number } | undefined {
  let end = text.length;
  if (text.endsWith("\r\n")) end -= 2;
  else if (text.endsWith("\r") || text.endsWith("\n")) end -= 1;
  else return undefined;
  if (end < contentStart) return undefined;
  const start = Math.max(contentStart, physicalLineStart(text, end));
  return start >= contentStart ? { start, end } : undefined;
}

function freshFenceLine(_context: FenceContext): FenceLineState {
  return {
    phase: { kind: "container", index: 0, column: 0 },
    pendingColumns: 0
  };
}

function fenceLineStateForRange(
  text: string,
  start: number,
  end: number,
  context: FenceContext,
  marker: "`" | "~"
): FenceLineState {
  const line = freshFenceLine(context);
  for (let index = start; index < end; index += 1) {
    scannerCodeUnits += 1;
    const result = feedFenceCharacter(line, context, marker, text[index]);
    if (result.kind === "outside" || line.phase.kind === "content") break;
  }
  return line;
}

type FenceCharacterResult =
  | { kind: "accepted"; emitted: string }
  | { kind: "outside" };

function feedFenceCharacter(
  line: FenceLineState,
  context: FenceContext,
  marker: "`" | "~",
  character: string
): FenceCharacterResult {
  for (;;) {
    const phase = line.phase;
    switch (phase.kind) {
      case "container": {
        const container = context.containers[phase.index];
        if (!container) {
          const pendingColumns = line.pendingColumns;
          line.pendingColumns = 0;
          line.phase = {
            kind: "leading",
            whitespace: Array.from({ length: pendingColumns }, () => " "),
            columns: pendingColumns,
            startColumn: phase.column - pendingColumns,
            column: phase.column
          };
          continue;
        }
        line.phase =
          container.kind === "blockquote"
            ? {
                kind: "quoteIndent",
                index: phase.index,
                column: phase.column,
                indentColumns: 0
              }
            : {
                kind: "listIndent",
                index: phase.index,
                column: phase.column,
                consumedColumns: 0
              };
        continue;
      }
      case "quoteIndent": {
        if (line.pendingColumns > 0) {
          if (phase.indentColumns + line.pendingColumns > 3) {
            line.phase = { kind: "outside" };
            return { kind: "outside" };
          }
          phase.indentColumns += line.pendingColumns;
          line.pendingColumns = 0;
          continue;
        }
        if (isMarkdownWhitespace(character)) {
          const width = whitespaceWidth(character, phase.column);
          if (phase.indentColumns + width <= 3) {
            phase.indentColumns += width;
            phase.column += width;
            return { kind: "accepted", emitted: "" };
          }
        }
        if (character !== ">") {
          line.phase = { kind: "outside" };
          return { kind: "outside" };
        }
        line.phase = {
          kind: "quoteSpace",
          index: phase.index,
          column: phase.column + 1
        };
        return { kind: "accepted", emitted: "" };
      }
      case "quoteSpace": {
        if (isMarkdownWhitespace(character)) {
          const width = whitespaceWidth(character, phase.column);
          line.pendingColumns += Math.max(0, width - 1);
          line.phase = {
            kind: "container",
            index: phase.index + 1,
            column: phase.column + width
          };
          return { kind: "accepted", emitted: "" };
        }
        line.phase = {
          kind: "container",
          index: phase.index + 1,
          column: phase.column
        };
        continue;
      }
      case "listIndent": {
        const container = context.containers[phase.index];
        if (!container || container.kind !== "list") {
          line.phase = { kind: "outside" };
          return { kind: "outside" };
        }
        if (line.pendingColumns > 0) {
          const remaining = container.continuationColumns - phase.consumedColumns;
          const claimed = Math.min(line.pendingColumns, remaining);
          line.pendingColumns -= claimed;
          phase.consumedColumns += claimed;
          if (phase.consumedColumns === container.continuationColumns) {
            line.phase = {
              kind: "container",
              index: phase.index + 1,
              column: phase.column
            };
            continue;
          }
        }
        if (!isMarkdownWhitespace(character)) {
          line.phase = { kind: "outside" };
          return { kind: "outside" };
        }
        const width = whitespaceWidth(character, phase.column);
        const remaining = container.continuationColumns - phase.consumedColumns;
        phase.column += width;
        phase.consumedColumns += Math.min(width, remaining);
        if (width > remaining) line.pendingColumns += width - remaining;
        if (phase.consumedColumns === container.continuationColumns) {
          line.phase = {
            kind: "container",
            index: phase.index + 1,
            column: phase.column
          };
        }
        return { kind: "accepted", emitted: "" };
      }
      case "leading": {
        if (isMarkdownWhitespace(character)) {
          const width = whitespaceWidth(character, phase.column);
          phase.whitespace.push(character);
          phase.columns += width;
          phase.column += width;
          if (phase.columns <= 3) return { kind: "accepted", emitted: "" };
          line.phase = { kind: "content", column: phase.column };
          return {
            kind: "accepted",
            emitted: normalizedLeadingWhitespace(
              phase.whitespace,
              phase.startColumn,
              context.openingIndent
            )
          };
        }
        if (character === marker) {
          line.phase = {
            kind: "candidate",
            leadingWhitespace: phase.whitespace,
            leadingColumns: phase.columns,
            leadingStartColumn: phase.startColumn,
            markerCount: 1,
            trailingWhitespace: [],
            sawTrailingWhitespace: false,
            column: phase.column + 1
          };
          return { kind: "accepted", emitted: "" };
        }
        line.phase = { kind: "content", column: phase.column + 1 };
        return {
          kind: "accepted",
          emitted: `${normalizedLeadingWhitespace(
            phase.whitespace,
            phase.startColumn,
            context.openingIndent
          )}${character}`
        };
      }
      case "candidate":
        if (!phase.sawTrailingWhitespace && character === marker) {
          phase.markerCount += 1;
          phase.column += 1;
          return { kind: "accepted", emitted: "" };
        }
        if (isMarkdownWhitespace(character)) {
          phase.sawTrailingWhitespace = true;
          phase.trailingWhitespace.push(character);
          phase.column += whitespaceWidth(character, phase.column);
          return { kind: "accepted", emitted: "" };
        }
        line.phase = { kind: "content", column: phase.column + 1 };
        return {
          kind: "accepted",
          emitted: `${normalizedLeadingWhitespace(
            phase.leadingWhitespace,
            phase.leadingStartColumn,
            context.openingIndent
          )}${marker.repeat(phase.markerCount)}${phase.trailingWhitespace.join("")}${character}`
        };
      case "content":
        phase.column += isMarkdownWhitespace(character)
          ? whitespaceWidth(character, phase.column)
          : 1;
        return { kind: "accepted", emitted: character };
      case "outside":
        return { kind: "outside" };
    }
  }
}

function normalizedLeadingWhitespace(
  whitespace: string[],
  startColumn: number,
  removeColumns: number
): string {
  let column = startColumn;
  let expanded = "";
  for (const character of whitespace) {
    const width = whitespaceWidth(character, column);
    expanded += " ".repeat(width);
    column += width;
  }
  return expanded.slice(Math.min(removeColumns, expanded.length));
}

function pendingFenceLineText(
  line: FenceLineState,
  context: FenceContext,
  marker: "`" | "~"
): string {
  const phase = line.phase;
  if (phase.kind === "leading") {
    return normalizedLeadingWhitespace(
      phase.whitespace,
      phase.startColumn,
      context.openingIndent
    );
  }
  if (phase.kind !== "candidate") return "";
  return `${normalizedLeadingWhitespace(
    phase.leadingWhitespace,
    phase.leadingStartColumn,
    context.openingIndent
  )}${marker.repeat(phase.markerCount)}${phase.trailingWhitespace.join("")}`;
}

function isCompleteCloser(line: FenceLineState, minimum: number): boolean {
  return line.phase.kind === "candidate" && line.phase.markerCount >= minimum;
}

function appendToOpenFence(open: OpenFence, delta: string): "open" | "closed" | "fallback" {
  const initialLength = open.codeText.length;
  for (let index = 0; index < delta.length; index += 1) {
    const character = delta[index];
    scannerCodeUnits += 1;
    if (open.pendingLfKind) {
      const pendingKind = open.pendingLfKind;
      open.pendingLfKind = undefined;
      if (character === "\n") {
        if (pendingKind === "code") open.codeText += "\n";
        continue;
      }
    }
    if (character === "\r") {
      const result = finishFenceLine(open, "\r");
      if (result !== "open") return result;
      open.pendingLfKind = "code";
      continue;
    }
    if (character === "\n") {
      const result = finishFenceLine(open, "\n");
      if (result !== "open") return result;
      continue;
    }

    const result = feedFenceCharacter(open.line, open.context, open.marker, character);
    if (result.kind === "outside") return "fallback";
    if (result.emitted.length > 0) open.codeText += result.emitted;
  }

  open.eofClosed = isCompleteCloser(open.line, open.markerLength);
  if (open.codeText.length !== initialLength) open.source.store.update(open.codeText);
  return "open";
}

function finishFenceLine(
  open: OpenFence,
  lineEnding: "\r" | "\n"
): "open" | "closed" | "fallback" {
  if (open.line.phase.kind === "outside") return "fallback";
  if (isCompleteCloser(open.line, open.markerLength)) return "closed";

  if (open.line.phase.kind !== "content") {
    open.codeText += pendingFenceLineText(open.line, open.context, open.marker);
  }
  open.codeText += lineEnding;
  open.line = freshFenceLine(open.context);
  open.eofClosed = false;
  open.source.store.update(open.codeText);
  return "open";
}

function lineEndingBefore(source: string, offset: number): "\r\n" | "\r" | "\n" {
  if (source.slice(Math.max(0, offset - 2), offset) === "\r\n") return "\r\n";
  return source[offset - 1] === "\r" ? "\r" : "\n";
}

function physicalLineStart(text: string, offset: number): number {
  const before = Math.max(0, offset - 1);
  return Math.max(text.lastIndexOf("\n", before), text.lastIndexOf("\r", before)) + 1;
}

function physicalLineEnd(text: string, offset: number): number {
  for (let index = offset; index < text.length; index += 1) {
    if (text[index] === "\n") return index + 1;
    if (text[index] === "\r") return text[index + 1] === "\n" ? index + 2 : index + 1;
  }
  return text.length;
}

function endsWithLineBreak(text: string): boolean {
  return text.endsWith("\n") || text.endsWith("\r");
}

function parserProvenSafeBoundary(tree: Root, tail: string): number {
  if (tree.children.length < 2) return 0;
  let boundary = 0;
  for (let index = 1; index < tree.children.length; index += 1) {
    const nextStart = tree.children[index].position?.start.offset;
    if (nextStart === undefined || nextStart <= boundary) break;
    const unsafe = tail.indexOf("[", boundary);
    if (unsafe >= 0 && unsafe < nextStart) break;
    boundary = nextStart;
  }
  return boundary;
}
