import { useCallback, useEffect, useRef, useState } from "react";
import { getBridge } from "../../bridge";
import { Check, Copy } from "../Icons";
import { useCopy } from "../CopyContext";

/**
 * Inside a WKWebView loaded from file://, `navigator.clipboard` is often absent
 * or rejects. Falling through to the native `harness.copyText` bridge is what
 * makes copy actually work there — and confirming only after one of the two
 * resolves is what stops the button claiming success over an empty clipboard.
 */
async function writeClipboard(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // fall through to the native bridge
  }
  try {
    await getBridge().copyText({ text });
    return true;
  } catch {
    return false;
  }
}

export function CopyButton({
  text,
  className,
  label
}: {
  text: string;
  className?: string;
  label?: string;
}) {
  const copy = useCopy();
  const [copied, setCopied] = useState(false);
  const [failed, setFailed] = useState(false);
  const timer = useRef<number>(0);
  const alive = useRef(true);

  // Re-arm on every mount: StrictMode runs effect → cleanup → effect, so a
  // cleanup-only hook would leave `alive` false for the component's whole life
  // and silently drop the copied/failed confirmation.
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      if (timer.current) window.clearTimeout(timer.current);
    };
  }, []);

  const onClick = useCallback(
    (event: React.MouseEvent) => {
      event.stopPropagation();
      void writeClipboard(text).then((ok) => {
        if (!alive.current) return;
        setCopied(ok);
        setFailed(!ok);
        if (timer.current) window.clearTimeout(timer.current);
        timer.current = window.setTimeout(() => {
          if (!alive.current) return;
          setCopied(false);
          setFailed(false);
        }, 1100);
      });
    },
    [text]
  );

  const title = copied
    ? copy("supermux.harness.tool.copied")
    : failed
      ? copy("supermux.harness.tool.copyFailed")
      : label ?? copy("supermux.harness.tool.copy");

  return (
    <button
      type="button"
      className={`icon-btn copy-btn${copied ? " is-copied" : ""}${failed ? " is-failed" : ""}${
        className ? ` ${className}` : ""
      }`}
      onClick={onClick}
      title={title}
      aria-label={label ?? copy("supermux.harness.tool.copy")}
    >
      {copied ? <Check size={12} /> : <Copy size={12} />}
      {copied || failed ? <span className="copy-toast">{title}</span> : null}
    </button>
  );
}
