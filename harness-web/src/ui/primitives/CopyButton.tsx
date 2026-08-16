import { useCallback, useEffect, useRef, useState } from "react";
import { Check, Copy } from "../Icons";
import { useCopy } from "../CopyContext";

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
  const timer = useRef<number>(0);

  useEffect(
    () => () => {
      if (timer.current) window.clearTimeout(timer.current);
    },
    []
  );

  const onClick = useCallback(
    (event: React.MouseEvent) => {
      event.stopPropagation();
      const write = navigator.clipboard?.writeText(text);
      if (write) write.catch(() => undefined);
      setCopied(true);
      if (timer.current) window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => setCopied(false), 1100);
    },
    [text]
  );

  return (
    <button
      type="button"
      className={`icon-btn copy-btn${copied ? " is-copied" : ""}${className ? ` ${className}` : ""}`}
      onClick={onClick}
      title={copied ? copy("supermux.harness.tool.copied") : label ?? copy("supermux.harness.tool.copy")}
      aria-label={label ?? copy("supermux.harness.tool.copy")}
    >
      {copied ? <Check size={12} /> : <Copy size={12} />}
      {copied ? <span className="copy-toast">{copy("supermux.harness.tool.copied")}</span> : null}
    </button>
  );
}
