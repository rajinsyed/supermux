import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type RefObject
} from "react";

const INITIAL_ROWS = 26;
export const MAX_MOUNTED_TURNS = 48;
const WINDOW_STEP = 18;
const OVERSCAN_PX = 520;
const DEFAULT_HEIGHT = 132;

type Range = { start: number; end: number };

function tailRange(count: number): Range {
  return { start: Math.max(0, count - INITIAL_ROWS), end: count };
}

function equalRange(left: Range, right: Range): boolean {
  return left.start === right.start && left.end === right.end;
}

function sameIds(left: readonly string[], right: readonly string[]): boolean {
  if (left === right) return true;
  if (left.length !== right.length) return false;
  return left.every((id, index) => id === right[index]);
}

function clampRange(range: Range, count: number): Range {
  const start = Math.min(range.start, count);
  return { start, end: Math.min(Math.max(range.end, start), count) };
}

function remapRangeByIdentity({
  range,
  previousIds,
  nextIds,
  followsTail,
  reset
}: {
  range: Range;
  previousIds: readonly string[];
  nextIds: readonly string[];
  followsTail: boolean;
  reset: boolean;
}): Range {
  if (reset || followsTail) return tailRange(nextIds.length);
  if (nextIds.length === 0) return { start: 0, end: 0 };
  if (previousIds.length === 0) return tailRange(nextIds.length);
  const firstMountedId = previousIds[range.start];
  const remappedStart = firstMountedId === undefined ? -1 : nextIds.indexOf(firstMountedId);
  const width = Math.min(nextIds.length, Math.max(1, range.end - range.start));
  if (remappedStart < 0) {
    // Rewind can remove the whole mounted window. Clamp to the nearest surviving
    // tail with the same bounded width; `{count,count}` would blank a nonempty log.
    const end = nextIds.length;
    return { start: Math.max(0, end - width), end };
  }
  return {
    start: remappedStart,
    end: Math.min(nextIds.length, remappedStart + width)
  };
}

function indexAtOffset(offsets: number[], target: number): number {
  let low = 0;
  let high = Math.max(0, offsets.length - 1);
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (offsets[middle + 1] <= target) low = middle + 1;
    else high = middle;
  }
  return Math.min(low, Math.max(0, offsets.length - 2));
}

interface Anchor {
  id: string;
  top: number;
}

export function useTranscriptWindow({
  turnIds,
  scrollRef,
  following,
  resetKey,
  onAnchorCorrection
}: {
  turnIds: readonly string[];
  scrollRef: RefObject<HTMLDivElement | null>;
  following?: RefObject<boolean>;
  resetKey: number;
  onAnchorCorrection?: (delta: number) => void;
}) {
  const [range, setRange] = useState<Range>(() => tailRange(turnIds.length));
  const [heightRevision, setHeightRevision] = useState(0);
  const heights = useRef(new Map<string, number>());
  const pendingHeights = useRef(new Map<string, number>());
  const previousTurnIds = useRef(turnIds);
  const previousReset = useRef(resetKey);
  const pendingAnchor = useRef<Anchor | undefined>(undefined);
  const lastAnchor = useRef<Anchor | undefined>(undefined);
  const scrollFrame = useRef(0);
  const measureFrame = useRef(0);
  const idsBeforeRender = previousTurnIds.current;
  const followsTail = following
    ? following.current
    : idsBeforeRender.length > 0 && range.end >= idsBeforeRender.length;
  const effectiveRange = remapRangeByIdentity({
    range,
    previousIds: idsBeforeRender,
    nextIds: turnIds,
    followsTail,
    reset: previousReset.current !== resetKey
  });

  const offsets = useMemo(() => {
    const values = new Array<number>(turnIds.length + 1);
    values[0] = 0;
    for (let index = 0; index < turnIds.length; index += 1) {
      // Unknown rows keep a fixed estimate. Letting the average follow the live
      // tail makes one growing answer resize hundreds of unseen spacer rows.
      values[index + 1] =
        values[index] + (heights.current.get(turnIds[index]) ?? DEFAULT_HEIGHT);
    }
    return values;
  }, [heightRevision, turnIds]);
  const indexById = useMemo(() => {
    const indices = new Map<string, number>();
    turnIds.forEach((id, index) => indices.set(id, index));
    return indices;
  }, [turnIds]);

  const readAnchor = useCallback((): Anchor | undefined => {
    const root = scrollRef.current;
    if (!root) return undefined;
    const rootTop = root.getBoundingClientRect().top;
    for (const node of root.querySelectorAll<HTMLElement>("[data-virtual-turn-id]")) {
      const rect = node.getBoundingClientRect();
      if (rect.bottom < rootTop) continue;
      return {
        id: node.dataset.virtualTurnId ?? "",
        top: rect.top - rootTop
      };
    }
    return undefined;
  }, [scrollRef]);

  const captureAnchor = useCallback(() => {
    const anchor = readAnchor();
    if (!anchor) return;
    pendingAnchor.current = anchor;
    lastAnchor.current = anchor;
  }, [readAnchor]);

  const setAnchoredRange = useCallback(
    (next: Range) => {
      if (!following?.current) captureAnchor();
      setRange((before) => (equalRange(before, next) ? before : next));
    },
    [captureAnchor, following]
  );

  const restoreAnchor = useCallback(
    (anchor: Anchor) => {
      const root = scrollRef.current;
      const node = root
        ? Array.from(root.querySelectorAll<HTMLElement>("[data-virtual-turn-id]")).find(
            (candidate) => candidate.dataset.virtualTurnId === anchor.id
          )
        : undefined;
      if (!root || !node) return;
      const current = node.getBoundingClientRect().top - root.getBoundingClientRect().top;
      const delta = current - anchor.top;
      if (Math.abs(delta) <= 0.5) return;
      if (onAnchorCorrection) onAnchorCorrection(delta);
      else root.scrollTop += delta;
    },
    [onAnchorCorrection, scrollRef]
  );

  useLayoutEffect(() => {
    const anchor = pendingAnchor.current;
    if (!anchor) return;
    pendingAnchor.current = undefined;
    restoreAnchor(anchor);
  }, [
    effectiveRange.end,
    effectiveRange.start,
    heightRevision,
    restoreAnchor,
    turnIds
  ]);

  useLayoutEffect(() => {
    if (previousReset.current === resetKey) return;
    previousReset.current = resetKey;
    previousTurnIds.current = turnIds;
    heights.current.clear();
    pendingHeights.current.clear();
    pendingAnchor.current = undefined;
    lastAnchor.current = undefined;
    setHeightRevision((value) => value + 1);
    setRange(tailRange(turnIds.length));
  }, [resetKey, turnIds]);

  useEffect(() => {
    if (turnIds.length === 0) return;
    const live = new Set(turnIds);
    let changed = false;
    for (const id of heights.current.keys()) {
      if (live.has(id)) continue;
      heights.current.delete(id);
      changed = true;
    }
    if (changed) setHeightRevision((value) => value + 1);
  }, [turnIds]);

  useLayoutEffect(() => {
    if (previousReset.current !== resetKey || turnIds.length === 0) return;
    const before = previousTurnIds.current;
    if (sameIds(before, turnIds)) {
      previousTurnIds.current = turnIds;
      return;
    }

    // Keep the identity and viewport geometry of the mounted window. Numeric
    // indices alone shift every visible row when history is prepended.
    const anchor = lastAnchor.current;
    if (!followsTail && anchor && turnIds.includes(anchor.id)) restoreAnchor(anchor);
    previousTurnIds.current = turnIds;
    setRange((current) => (equalRange(current, effectiveRange) ? current : effectiveRange));
  }, [
    effectiveRange.end,
    effectiveRange.start,
    followsTail,
    resetKey,
    restoreAnchor,
    turnIds
  ]);

  useLayoutEffect(() => {
    if (pendingAnchor.current) return;
    lastAnchor.current = readAnchor();
  }, [effectiveRange.end, effectiveRange.start, heightRevision, readAnchor, turnIds]);

  const updateForScroll = useCallback(() => {
    const root = scrollRef.current;
    const count = turnIds.length;
    // DOM-only tests have no layout box; retaining the explicit tail range there
    // keeps the behavioral seam deterministic while browsers use real geometry.
    if (!root || count === 0 || root.clientHeight <= 0) return;
    // Follow and smooth-jump own the tail. Intermediate scroll positions during
    // a smooth jump must not re-window away from the destination they target.
    if (following?.current) {
      setRange((current) => {
        const tail = tailRange(count);
        return equalRange(current, tail) ? current : tail;
      });
      return;
    }
    const topSpacer = root.querySelector<HTMLElement>(".transcript-spacer.is-top");
    const origin = topSpacer
      ? topSpacer.getBoundingClientRect().top - root.getBoundingClientRect().top + root.scrollTop
      : 0;
    const top = Math.max(0, root.scrollTop - origin - OVERSCAN_PX);
    const bottom = Math.max(0, root.scrollTop - origin + root.clientHeight + OVERSCAN_PX);
    let start = indexAtOffset(offsets, top);
    let end = Math.min(count, indexAtOffset(offsets, bottom) + 1);
    if (end - start < INITIAL_ROWS) {
      const missing = INITIAL_ROWS - (end - start);
      start = Math.max(0, start - Math.ceil(missing / 2));
      end = Math.min(count, Math.max(end, start + INITIAL_ROWS));
      start = Math.max(0, end - INITIAL_ROWS);
    }
    if (end - start > MAX_MOUNTED_TURNS) end = Math.min(count, start + MAX_MOUNTED_TURNS);
    setAnchoredRange({ start, end });
  }, [following, offsets, scrollRef, setAnchoredRange, turnIds.length]);

  useEffect(() => {
    const root = scrollRef.current;
    if (!root) return;
    const schedule = () => {
      if (scrollFrame.current) return;
      scrollFrame.current = requestAnimationFrame(() => {
        scrollFrame.current = 0;
        updateForScroll();
      });
    };
    root.addEventListener("scroll", schedule, { passive: true });
    const observer =
      typeof ResizeObserver !== "undefined" ? new ResizeObserver(schedule) : undefined;
    observer?.observe(root);
    schedule();
    return () => {
      root.removeEventListener("scroll", schedule);
      observer?.disconnect();
      if (scrollFrame.current) cancelAnimationFrame(scrollFrame.current);
      scrollFrame.current = 0;
    };
  }, [scrollRef, updateForScroll]);

  const measure = useCallback(
    (id: string, height: number) => {
      if (!Number.isFinite(height) || height <= 0) return;
      const before = pendingHeights.current.get(id) ?? heights.current.get(id);
      if (before !== undefined && Math.abs(before - height) < 0.5) return;
      const anchor = lastAnchor.current;
      const measuredIndex = indexById.get(id);
      const anchorIndex = anchor ? indexById.get(anchor.id) : undefined;
      if (
        !following?.current &&
        before !== undefined &&
        measuredIndex !== undefined &&
        anchorIndex !== undefined &&
        measuredIndex < anchorIndex
      ) {
        // ResizeObserver fires after layout has already moved the visible row.
        // Correct from the previously recorded anchor and the old measured height
        // before publishing the new spacer measurement; capturing now would save
        // the shifted geometry and make the movement permanent.
        const delta = height - before;
        if (Math.abs(delta) >= 0.5) {
          if (onAnchorCorrection) onAnchorCorrection(delta);
          else if (scrollRef.current) scrollRef.current.scrollTop += delta;
        }
      }
      pendingHeights.current.set(id, height);
      if (measureFrame.current) return;
      measureFrame.current = requestAnimationFrame(() => {
        measureFrame.current = 0;
        let changed = false;
        for (const [pendingId, pendingHeight] of pendingHeights.current) {
          const current = heights.current.get(pendingId);
          if (current === undefined || Math.abs(current - pendingHeight) >= 0.5) {
            heights.current.set(pendingId, pendingHeight);
            changed = true;
          }
        }
        pendingHeights.current.clear();
        if (changed) setHeightRevision((value) => value + 1);
      });
    },
    [following, indexById, onAnchorCorrection, scrollRef]
  );

  useEffect(
    () => () => {
      if (measureFrame.current) cancelAnimationFrame(measureFrame.current);
    },
    []
  );

  const showEarlier = useCallback(() => {
    if (following) following.current = false;
    captureAnchor();
    setRange((before) => {
      const start = Math.max(0, before.start - WINDOW_STEP);
      // Keep one overlap row while a button-driven page settles so the measured
      // anchor is always present on both sides. Once the beginning is reached,
      // compact to the ordinary hard limit. Scroll-driven ranges never exceed it.
      const width = start === 0 ? MAX_MOUNTED_TURNS : MAX_MOUNTED_TURNS + 1;
      const end = Math.min(turnIds.length, start + width);
      const next = { start, end };
      return equalRange(before, next) ? before : next;
    });
  }, [captureAnchor, following, turnIds.length]);

  const showLater = useCallback(() => {
    captureAnchor();
    setRange((before) => {
      const end = Math.min(turnIds.length, before.end + WINDOW_STEP);
      const start = Math.max(0, end - MAX_MOUNTED_TURNS);
      const next = { start, end };
      return equalRange(before, next) ? before : next;
    });
  }, [captureAnchor, turnIds.length]);

  const showLatest = useCallback(() => {
    if (following) following.current = true;
    setRange(tailRange(turnIds.length));
  }, [following, turnIds.length]);

  const clamped = clampRange(effectiveRange, turnIds.length);

  return {
    range: clamped,
    topHeight: offsets[clamped.start] ?? 0,
    bottomHeight: (offsets[turnIds.length] ?? 0) - (offsets[clamped.end] ?? 0),
    measure,
    showEarlier,
    showLater,
    showLatest
  };
}
