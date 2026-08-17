import { useCallback, useEffect, useRef, useState } from "react";

const REARM_THRESHOLD = 44;

export function useScrollFollow(deps: unknown[]) {
  const ref = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  const [showPill, setShowPill] = useState(false);

  const atBottom = useCallback(() => {
    const node = ref.current;
    if (!node) return true;
    return node.scrollHeight - node.scrollTop - node.clientHeight <= REARM_THRESHOLD;
  }, []);

  const scrollToBottom = useCallback((smooth = false) => {
    const node = ref.current;
    if (!node) return;
    following.current = true;
    setShowPill(false);
    node.scrollTo({ top: node.scrollHeight, behavior: smooth ? "smooth" : "auto" });
  }, []);

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const onScroll = () => {
      const bottom = atBottom();
      if (bottom) {
        following.current = true;
        setShowPill(false);
      } else if (following.current) {
        following.current = false;
        setShowPill(true);
      }
    };
    node.addEventListener("scroll", onScroll, { passive: true });
    return () => node.removeEventListener("scroll", onScroll);
  }, [atBottom]);

  useEffect(() => {
    if (!following.current) return;
    const node = ref.current;
    if (!node) return;
    const frame = requestAnimationFrame(() => {
      node.scrollTop = node.scrollHeight;
    });
    return () => cancelAnimationFrame(frame);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  // A permission/question card grows AFTER the effect above runs (its preview,
  // diff, or option list mounts a frame later), leaving the primary button
  // clipped behind the dock with no pill to explain it. Following the content's
  // own size keeps the bottom pinned through that growth, and re-evaluates the
  // pill when the user is not following.
  useEffect(() => {
    const content = contentRef.current;
    const node = ref.current;
    if (!content || !node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => {
      if (following.current) {
        node.scrollTop = node.scrollHeight;
        return;
      }
      setShowPill(!atBottom());
    });
    observer.observe(content);
    return () => observer.disconnect();
  }, [atBottom]);

  return { ref, contentRef, showPill, scrollToBottom, isFollowing: following };
}
