import type { JsonObject } from "../protocol/types";
import { isPlainObject } from "./helpers";
import type { ToolBlock, ToolResultTextSource } from "./types";

interface NormalizedToolResultPayload {
  structured: JsonObject | undefined;
  resultTextSources: ToolResultTextSource[] | undefined;
}

export function normalizeToolResultPayload(
  resultText: string,
  structured: JsonObject | undefined
): NormalizedToolResultPayload {
  if (!structured || resultText.length === 0) {
    return { structured, resultTextSources: undefined };
  }

  const resultTextSources: ToolResultTextSource[] = [];
  let normalized = structured;
  const removeTopLevelDuplicate = (key: "stdout" | "stderr" | "content") => {
    if (normalized[key] !== resultText) return;
    if (normalized === structured) normalized = { ...structured };
    delete normalized[key];
    resultTextSources.push(key);
  };

  removeTopLevelDuplicate("stdout");
  removeTopLevelDuplicate("stderr");
  removeTopLevelDuplicate("content");

  const file = normalized.file;
  if (isPlainObject(file) && file.content === resultText) {
    if (normalized === structured) normalized = { ...structured };
    const normalizedFile = { ...file };
    delete normalizedFile.content;
    normalized.file = normalizedFile;
    resultTextSources.push("fileContent");
  }

  return {
    structured: normalized,
    resultTextSources: resultTextSources.length > 0 ? resultTextSources : undefined
  };
}

export function canonicalToolResultText(
  block: ToolBlock,
  source: ToolResultTextSource
): string | undefined {
  if (block.resultTextSources?.includes(source)) return block.resultText;
  switch (source) {
    case "stdout":
      return nonemptyString(block.structured?.stdout);
    case "stderr":
      return nonemptyString(block.structured?.stderr);
    case "content":
      return nonemptyString(block.structured?.content);
    case "fileContent": {
      const file = block.structured?.file;
      return isPlainObject(file) ? nonemptyString(file.content) : undefined;
    }
    default: {
      const exhaustive: never = source;
      return exhaustive;
    }
  }
}

function nonemptyString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
