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

const MAX_HIGHLIGHT_CHARS = 80000;
const CACHE_LIMIT = 240;
const cache = new Map<string, string>();

export function supportsLanguage(language: string | undefined): boolean {
  if (!language) return false;
  return hljs.getLanguage(language.toLowerCase()) !== undefined;
}

export function highlightToHtml(code: string, language: string | undefined, cacheable = true): string {
  if (code.length > MAX_HIGHLIGHT_CHARS || !supportsLanguage(language)) return escapeHtml(code);
  const key = cacheable ? `${language}:${code.length}:${hash(code)}` : "";
  if (key) {
    const hit = cache.get(key);
    if (hit !== undefined) return hit;
  }
  let html: string;
  try {
    html = hljs.highlight(code, { language: language!.toLowerCase(), ignoreIllegals: true }).value;
  } catch {
    html = escapeHtml(code);
  }
  if (key) {
    if (cache.size >= CACHE_LIMIT) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
    cache.set(key, html);
  }
  return html;
}

export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function hash(text: string): string {
  let h = 2166136261;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(36);
}
