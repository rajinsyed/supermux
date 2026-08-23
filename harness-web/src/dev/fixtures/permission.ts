import type { ProtocolLine } from "../../protocol/types";
import {
  assistantText,
  canUseTool,
  initLine,
  initializeResponse,
  messageStart,
  messageStop,
  resultLine,
  sessionState,
  statusLine,
  streamThinking,
  streamToolUse,
  toolResult,
  userLine
} from "./build";

const MSG = "msg_perm_0001";
const BASH_ID = "toolu_perm-bash-1";
const EDIT_ID = "toolu_perm-edit-1";

export const permissionFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine(),
  userLine("Run the migration script and then rename `applyPatch` to `applyDiff` in patch.ts."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG),
  ...streamThinking(
    MSG,
    0,
    "The user wants two operations. First run the migration, which needs shell access, then perform a rename in patch.ts. I'll ask for permission on the shell command since it mutates the database.",
    186
  ),
  ...streamToolUse(MSG, 1, BASH_ID, "Bash", {
    command: "bun run db:migrate --env staging",
    description: "Apply pending migrations against staging"
  }),
  messageStop(),
  sessionState("requires_action"),
  canUseTool("req-bash-1", "Bash", {
    command: "bun run db:migrate --env staging",
    description: "Apply pending migrations against staging"
  }, {
    title: "Run staging migrations",
    description: "Apply pending migrations against staging",
    decision_reason: "This command modifies a database and requires approval",
    permission_suggestions: [
      {
        type: "addRules",
        rules: [{ toolName: "Bash", ruleContent: "bun run db:migrate:*" }],
        behavior: "allow",
        destination: "localSettings"
      },
      { type: "addDirectories", directories: ["/Users/dev/projects/supermux"], destination: "session" }
    ],
    tool_use_id: BASH_ID
  })
];

const MIGRATION_OUTPUT = `\u001b[36m→\u001b[0m connecting to staging…
\u001b[32m✓\u001b[0m 0034_add_harness_panels.sql   (128ms)
\u001b[32m✓\u001b[0m 0035_backfill_titles.sql      (2,041ms)
\u001b[33m!\u001b[0m 0036_drop_legacy_index.sql    skipped (already applied)
\u001b[32m✓\u001b[0m migrations complete — 2 applied, 1 skipped`;

export const permissionResolution: ProtocolLine[] = [
  toolResult(BASH_ID, MIGRATION_OUTPUT, {
    stdout: MIGRATION_OUTPUT,
    stderr: "",
    interrupted: false,
    isImage: false
  }),
  sessionState("running"),
  ...streamToolUse(MSG, 2, EDIT_ID, "Edit", {
    file_path: "/Users/dev/projects/supermux/src/patch.ts",
    old_string: "export function applyPatch(",
    new_string: "export function applyDiff(",
    replace_all: true
  }),
  sessionState("requires_action"),
  canUseTool("req-edit-1", "Edit", {
    file_path: "/Users/dev/projects/supermux/src/patch.ts",
    old_string: "export function applyPatch(",
    new_string: "export function applyDiff(",
    replace_all: true
  }, {
    title: "Edit patch.ts",
    permission_suggestions: [
      {
        type: "addRules",
        rules: [{ toolName: "Edit", ruleContent: "/Users/dev/projects/supermux/src/**" }],
        behavior: "allow",
        destination: "projectSettings"
      },
      { type: "setMode", mode: "acceptEdits", destination: "session" }
    ],
    tool_use_id: EDIT_ID
  })
];

export const permissionCompletion: ProtocolLine[] = [
  toolResult(
    EDIT_ID,
    "The file /Users/dev/projects/supermux/src/patch.ts has been updated.",
    {
      filePath: "/Users/dev/projects/supermux/src/patch.ts",
      userModified: false,
      structuredPatch: [
        {
          oldStart: 42,
          oldLines: 6,
          newStart: 42,
          newLines: 6,
          lines: [
            " import { structuredPatch } from \"./diff\";",
            " ",
            "-export function applyPatch(target: string, hunks: Hunk[]): string {",
            "+export function applyDiff(target: string, hunks: Hunk[]): string {",
            "   const lines = target.split(\"\\n\");",
            "   let offset = 0;"
          ]
        },
        {
          oldStart: 118,
          oldLines: 4,
          newStart: 118,
          newLines: 4,
          lines: [
            "   for (const hunk of hunks) {",
            "-    result = applyPatch(result, [hunk]);",
            "+    result = applyDiff(result, [hunk]);",
            "   }"
          ]
        }
      ]
    }
  ),
  assistantText(
    MSG,
    "Migrations applied (2 new, 1 already present) and `applyPatch` is now `applyDiff` across `patch.ts` — both the declaration and the recursive call site."
  ),
  statusLine(null),
  resultLine({
    result:
      "Migrations applied (2 new, 1 already present) and `applyPatch` is now `applyDiff` across `patch.ts`.",
    num_turns: 3,
    total_cost_usd: 0.0914
  })
];
