import { isPlainObject } from "./helpers";
import { validateImagePayload } from "./attachments";

export interface InlineImagePayload {
  mediaType: string;
  dataBase64: string;
}

export interface ParsedToolResultContent {
  text: string;
  images: InlineImagePayload[];
}

/** Accept only the same bounded image payloads the composer can send to Claude. */
export function inlineImagePayload(content: unknown): InlineImagePayload | undefined {
  if (!isPlainObject(content) || content.type !== "image" || !isPlainObject(content.source)) {
    return undefined;
  }
  const source = content.source;
  if (
    source.type !== "base64" ||
    typeof source.media_type !== "string" ||
    typeof source.data !== "string"
  ) {
    return undefined;
  }
  const payload = { mediaType: source.media_type, dataBase64: source.data };
  return validateImagePayload(payload).kind === "valid" ? payload : undefined;
}

/** Preserve textual tool output while separating structured images for inline rendering. */
export function parseToolResultContent(content: unknown): ParsedToolResultContent {
  if (typeof content === "string") return { text: content, images: [] };
  if (Array.isArray(content)) {
    const text: string[] = [];
    const images: InlineImagePayload[] = [];
    for (const part of content) {
      if (typeof part === "string") {
        text.push(part);
        continue;
      }
      if (isPlainObject(part) && typeof part.text === "string") {
        text.push(part.text);
        continue;
      }
      const image = inlineImagePayload(part);
      if (image) images.push(image);
    }
    return { text: text.filter(Boolean).join("\n"), images };
  }
  if (content === undefined || content === null) return { text: "", images: [] };
  return { text: JSON.stringify(content, null, 2), images: [] };
}
