import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import csharp from "highlight.js/lib/languages/csharp";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import go from "highlight.js/lib/languages/go";
import ini from "highlight.js/lib/languages/ini";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import kotlin from "highlight.js/lib/languages/kotlin";
import markdown from "highlight.js/lib/languages/markdown";
import objectivec from "highlight.js/lib/languages/objectivec";
import php from "highlight.js/lib/languages/php";
import python from "highlight.js/lib/languages/python";
import ruby from "highlight.js/lib/languages/ruby";
import rust from "highlight.js/lib/languages/rust";
import scss from "highlight.js/lib/languages/scss";
import sql from "highlight.js/lib/languages/sql";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import { utf8ByteLength } from "./utf8";

const LANGUAGES: Record<string, Parameters<typeof hljs.registerLanguage>[1]> = {
  bash,
  c,
  cpp,
  csharp,
  css,
  diff,
  go,
  ini,
  java,
  javascript,
  json,
  kotlin,
  markdown,
  objectivec,
  php,
  python,
  ruby,
  rust,
  scss,
  sql,
  swift,
  typescript,
  xml,
  yaml
};

for (const [name, language] of Object.entries(LANGUAGES)) hljs.registerLanguage(name, language);
hljs.registerAliases(["ts", "tsx"], { languageName: "typescript" });
hljs.registerAliases(["js", "jsx", "mjs", "cjs"], { languageName: "javascript" });
hljs.registerAliases(["sh", "zsh", "shell", "console"], { languageName: "bash" });
hljs.registerAliases(["yml"], { languageName: "yaml" });
hljs.registerAliases(["html", "svg"], { languageName: "xml" });
hljs.registerAliases(["toml"], { languageName: "ini" });
hljs.registerAliases(["md"], { languageName: "markdown" });
hljs.registerAliases(["objc", "obj-c"], { languageName: "objectivec" });
hljs.registerAliases(["cs"], { languageName: "csharp" });
hljs.registerAliases(["patch"], { languageName: "diff" });
hljs.registerAliases(["py"], { languageName: "python" });
hljs.registerAliases(["rs"], { languageName: "rust" });
hljs.registerAliases(["rb"], { languageName: "ruby" });
hljs.registerAliases(["kt"], { languageName: "kotlin" });

const MAX_HIGHLIGHT_BYTES = 512 * 1024;
const CACHE_BUDGET_BYTES = 4 * 1024 * 1024;
const MAX_CACHE_ENTRY_BYTES = 256 * 1024;
const CACHE_ENTRY_LIMIT = 120;

interface CacheEntry {
  html: string;
  bytes: number;
}

const cache = new Map<string, CacheEntry>();
let cacheBytes = 0;

export function supportsLanguage(language: string | undefined): boolean {
  if (!language) return false;
  return hljs.getLanguage(language.toLowerCase()) !== undefined;
}

export function highlightToHtml(code: string, language: string | undefined, cacheable = true): string {
  if (utf8ByteLength(code) > MAX_HIGHLIGHT_BYTES || !supportsLanguage(language)) {
    return escapeHtml(code);
  }
  const normalizedLanguage = language!.toLowerCase();
  // Exact source identity avoids hash collisions returning another snippet's
  // markup. Its bytes count toward the same budget as the generated HTML.
  const key = cacheable ? `${normalizedLanguage}\0${code}` : "";
  if (key) {
    const hit = cache.get(key);
    if (hit) {
      cache.delete(key);
      cache.set(key, hit);
      return hit.html;
    }
  }

  let html: string;
  try {
    html = hljs.highlight(code, {
      language: normalizedLanguage,
      ignoreIllegals: true
    }).value;
  } catch {
    html = escapeHtml(code);
  }

  if (key) {
    const bytes = utf8ByteLength(key) + utf8ByteLength(html);
    if (bytes <= MAX_CACHE_ENTRY_BYTES) {
      while (
        cache.size >= CACHE_ENTRY_LIMIT ||
        cacheBytes + bytes > CACHE_BUDGET_BYTES
      ) {
        const oldest = cache.entries().next().value as [string, CacheEntry] | undefined;
        if (!oldest) break;
        cache.delete(oldest[0]);
        cacheBytes -= oldest[1].bytes;
      }
      cache.set(key, { html, bytes });
      cacheBytes += bytes;
    }
  }
  return html;
}

export function highlightCacheStats(): { entries: number; bytes: number; budgetBytes: number } {
  return { entries: cache.size, bytes: cacheBytes, budgetBytes: CACHE_BUDGET_BYTES };
}

export function clearHighlightCache(): void {
  cache.clear();
  cacheBytes = 0;
}

export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
