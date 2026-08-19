export interface Utf8Clip {
  text: string;
  bytes: number;
  truncated: boolean;
}

function codePointWidth(codePoint: number): number {
  if (codePoint <= 0x7f) return 1;
  if (codePoint <= 0x7ff) return 2;
  if (codePoint <= 0xffff) return 3;
  return 4;
}

/** UTF-8 byte length without allocating an encoded copy. */
export function utf8ByteLength(text: string): number {
  let bytes = 0;
  for (const character of text) {
    bytes += codePointWidth(character.codePointAt(0) ?? 0);
  }
  return bytes;
}

/** Prefix a string at a UTF-8 boundary, never splitting a surrogate pair. */
export function clipUtf8(text: string, maxBytes: number): Utf8Clip {
  const limit = Math.max(0, Math.floor(maxBytes));
  let bytes = 0;
  let end = 0;
  for (let index = 0; index < text.length; ) {
    const codePoint = text.codePointAt(index) ?? 0;
    const width = codePointWidth(codePoint);
    if (bytes + width > limit) break;
    const units = codePoint > 0xffff ? 2 : 1;
    bytes += width;
    index += units;
    end = index;
  }
  return { text: text.slice(0, end), bytes, truncated: end < text.length };
}

export function isAnsiControlStart(code: number): boolean {
  return code === 0x1b || (code >= 0x80 && code <= 0x9f);
}

/**
 * End offset for one ECMA-48 control. Both seven-bit ESC forms and their C1
 * single-code-point equivalents are recognized. Undefined means the source
 * ends inside a control and callers must stop before its introducer.
 */
export function ansiControlSequenceEnd(text: string, start: number): number | undefined {
  const first = text.charCodeAt(start);
  if (first >= 0x80 && first <= 0x9f) {
    if (first === 0x9b) return csiEnd(text, start + 1);
    if (first === 0x9d) return stringControlEnd(text, start + 1, true);
    if (first === 0x90 || first === 0x98 || first === 0x9e || first === 0x9f) {
      return stringControlEnd(text, start + 1, false);
    }
    return start + 1;
  }

  if (first !== 0x1b || start + 1 >= text.length) return undefined;
  const introducer = text[start + 1];
  if (introducer === "[") return csiEnd(text, start + 2);
  if (introducer === "]") return stringControlEnd(text, start + 2, true);
  if (introducer === "P" || introducer === "X" || introducer === "^" || introducer === "_") {
    return stringControlEnd(text, start + 2, false);
  }

  // ESC plus one code point is atomic even for malformed/non-ASCII controls;
  // never leave half of a surrogate pair in the preview.
  const codePoint = text.codePointAt(start + 1) ?? 0;
  return start + (codePoint > 0xffff ? 3 : 2);
}

function csiEnd(text: string, contentStart: number): number | undefined {
  for (let index = contentStart; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    // CAN and SUB terminate a control sequence without applying it. Treat the
    // canceled prefix as consumed so ordinary text after it remains visible.
    if (code === 0x18 || code === 0x1a) return index + 1;
    if (code >= 0x40 && code <= 0x7e) return index + 1;
    if (!((code >= 0x20 && code <= 0x3f))) return undefined;
  }
  return undefined;
}

function stringControlEnd(
  text: string,
  contentStart: number,
  bellTerminates: boolean
): number | undefined {
  for (let index = contentStart; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code === 0x18 || code === 0x1a) return index + 1;
    if (bellTerminates && code === 0x07) return index + 1;
    if (code === 0x9c) return index + 1;
    if (code === 0x1b && text[index + 1] === "\\") return index + 2;
  }
  return undefined;
}

/**
 * UTF-8 clipping for terminal text. ANSI controls are admitted atomically: when
 * the budget lands inside CSI/OSC/DCS, the preview stops before the introducer
 * instead of exposing a raw prefix such as "[38;5;" as visible output.
 */
export function clipAnsiUtf8(text: string, maxBytes: number): Utf8Clip {
  const limit = Math.max(0, Math.floor(maxBytes));
  let bytes = 0;
  let end = 0;
  let index = 0;
  while (index < text.length) {
    const code = text.charCodeAt(index);
    if (isAnsiControlStart(code)) {
      const sequenceEnd = ansiControlSequenceEnd(text, index);
      if (sequenceEnd === undefined) break;
      const sequence = text.slice(index, sequenceEnd);
      const width = utf8ByteLength(sequence);
      if (bytes + width > limit) break;
      bytes += width;
      index = sequenceEnd;
      end = index;
      continue;
    }
    const codePoint = text.codePointAt(index) ?? 0;
    const width = codePointWidth(codePoint);
    if (bytes + width > limit) break;
    index += codePoint > 0xffff ? 2 : 1;
    bytes += width;
    end = index;
  }
  return { text: text.slice(0, end), bytes, truncated: end < text.length };
}

export function lineCount(text: string): number {
  if (text.length === 0) return 1;
  let count = 1;
  for (let index = 0; index < text.length; index += 1) {
    if (text.charCodeAt(index) === 10) count += 1;
  }
  return count;
}
