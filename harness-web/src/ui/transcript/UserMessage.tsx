import { memo, useState } from "react";
import type { ImageAttachment } from "../../model/types";
import { useCopy } from "../CopyContext";
import { CopyButton } from "../primitives/CopyButton";

const COLLAPSE_LINES = 9;
const COLLAPSE_CHARS = 620;

export const UserMessage = memo(function UserMessage({
  text,
  images
}: {
  text: string;
  images?: ImageAttachment[];
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
      <CopyButton text={text} className="user-msg-copy" />
    </div>
  );
});
