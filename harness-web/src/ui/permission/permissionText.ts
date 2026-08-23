import type { CanUseToolRequest, PermissionSuggestion } from "../../protocol/types";
import type { CopyFn } from "../CopyContext";

export interface AlwaysAllowOffer {
  suggestion: PermissionSuggestion;
  rule: string;
  destination: string;
}

export function alwaysAllowOffer(
  request: CanUseToolRequest,
  copy: CopyFn
): AlwaysAllowOffer | undefined {
  if (request.suppress_always_allow_rule) return undefined;
  const suggestions = request.permission_suggestions ?? [];
  const addRules = suggestions.find(
    (s): s is Extract<PermissionSuggestion, { type: "addRules" }> =>
      s.type === "addRules" && Array.isArray((s as { rules?: unknown }).rules)
  );
  if (!addRules) return undefined;
  const first = addRules.rules[0];
  if (!first) return undefined;
  const rule = first.ruleContent ? `${first.toolName}(${first.ruleContent})` : first.toolName;
  return { suggestion: addRules, rule, destination: destinationLabel(addRules.destination, copy) };
}

export function destinationLabel(destination: string | undefined, copy: CopyFn): string {
  switch (destination) {
    case "localSettings":
      return copy("supermux.harness.permission.destinationLocal");
    case "projectSettings":
      return copy("supermux.harness.permission.destinationProject");
    case "userSettings":
      return copy("supermux.harness.permission.destinationUser");
    default:
      return copy("supermux.harness.permission.destinationSession");
  }
}

export function permissionHeadline(request: CanUseToolRequest): string {
  return request.title ?? request.display_name ?? request.tool_name;
}

export function setModeSuggestion(
  request: CanUseToolRequest,
  mode: string
): PermissionSuggestion {
  const existing = (request.permission_suggestions ?? []).find(
    (s) => s.type === "setMode" && (s as { mode?: string }).mode === mode
  );
  return existing ?? { type: "setMode", mode, destination: "session" };
}
