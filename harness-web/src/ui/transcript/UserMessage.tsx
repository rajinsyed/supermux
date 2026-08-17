import { memo, useState } from "react";
import type { ImageAttachment } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Rewind } from "../Icons";
import { CopyButton } from "../primitives/CopyButton";

const COLLAPSE_LINES = 9;
const COLLAPSE_CHARS = 620;

export const UserMessage = memo(function UserMessage({
  text,
  images,
  onRewind
}: {
  text: string;
  images?: ImageAttachment[];
  /**
   * Absent when the message carries no uuid — a locally-synthesised turn with
   * nothing for the CLI to rewind to. The button is omitted rather than shown
   * disabled: a rewind affordance that cannot rewind is worse than none.
   */
  onRewind?: () => void;
}) {
  const copy = useCopy();
  const [expanded, setExpanded] = useState(false);
  const lineCount = text.split("\n").length;
  const long = lineCount > COLLAPSE_LINES || text.length > COLLAPSE_CHARS;

  return (
    <div className="user-msg">
      <div className={`user-msg-body${long && !expanded ? " is-clipped" : ""}`}>{text}</div>
      {images && images.length > 0 ? (
        <div className="user-msg-images">
          {images.map((image, i) => (
            <img key={i} src={`data:${image.mediaType};base64,${image.dataBase64}`} alt={image.name ?? ""} />
          ))}
        </div>
      ) : null}
      {long ? (
        <div className="user-msg-actions">
          <button type="button" className="link-btn" onClick={() => setExpanded((v) => !v)}>
            {expanded
              ? copy("supermux.harness.turn.showLess")
              : copy("supermux.harness.turn.showFullMessage")}
          </button>
        </div>
      ) : null}
      <div className="user-msg-tools">
        {onRewind ? (
          <button
            type="button"
            className="icon-btn user-msg-rewind"
            onClick={onRewind}
            title={copy("supermux.harness.rewind.action")}
            aria-label={copy("supermux.harness.rewind.action")}
          >
            <Rewind size={12} />
          </button>
        ) : null}
        <CopyButton text={text} />
      </div>
    </div>
  );
});
