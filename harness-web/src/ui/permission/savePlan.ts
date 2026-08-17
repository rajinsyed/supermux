import { getBridge } from "../../bridge";

function slugify(title: string | undefined): string {
  const base = (title ?? "plan")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
  return base.length > 0 ? base : "plan";
}

/**
 * A WKWebView loaded from file:// silently ignores `<a download>`, so the native
 * save panel is the real path and the anchor is only the dev-browser fallback.
 */
export async function savePlanMarkdown(plan: string, title?: string): Promise<boolean> {
  const suggestedName = `${slugify(title)}.md`;
  try {
    const result = await getBridge().saveFile({ suggestedName, text: plan });
    if (result?.saved) return true;
  } catch {
    // fall through to the anchor download
  }
  if (typeof document === "undefined" || typeof URL.createObjectURL !== "function") return false;
  const url = URL.createObjectURL(new Blob([plan], { type: "text/markdown;charset=utf-8" }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = suggestedName;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 4000);
  return true;
}
