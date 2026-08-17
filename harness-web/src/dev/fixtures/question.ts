import type { ProtocolLine } from "../../protocol/types";
import {
  canUseTool,
  initLine,
  initializeResponse,
  messageStart,
  messageStop,
  resultLine,
  sessionState,
  statusLine,
  streamText,
  streamThinking,
  toolResult,
  userLine
} from "./build";

const MSG = "msg_question_0001";
const QUESTION_ID = "toolu_req-question-1";

export const questionFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine(),
  userLine("Set up authentication for the new dashboard."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG),
  ...streamThinking(
    MSG,
    0,
    "Several viable auth strategies exist here and the choice changes the whole implementation. I should ask before writing code.",
    142
  ),
  ...streamText(
    MSG,
    1,
    "Before I scaffold anything, the auth strategy determines the entire shape of the implementation. Two decisions matter:"
  ),
  messageStop(),
  sessionState("requires_action"),
  canUseTool("req-question-1", "AskUserQuestion", {
    questions: [
      {
        question: "Which authentication provider should the dashboard use?",
        header: "Auth provider",
        multiSelect: false,
        options: [
          {
            label: "Stack Auth",
            description: "Matches the existing web app. Shares the session cookie and the user table."
          },
          {
            label: "Clerk",
            description: "Fastest to integrate, hosted UI components, but a second user directory."
          },
          {
            label: "Custom JWT",
            description: "Full control, no vendor. Roughly two extra days of work plus rotation handling."
          }
        ]
      },
      {
        question: "Which surfaces need to be gated behind login on day one?",
        header: "Gated surfaces",
        multiSelect: true,
        options: [
          { label: "Billing", description: "Invoices, plan changes, payment methods." },
          { label: "Team settings", description: "Member invites, roles, SSO configuration." },
          { label: "Usage analytics", description: "Per-workspace token and cost dashboards." },
          { label: "Public status page", description: "Currently unauthenticated; gating it breaks embeds." }
        ]
      }
    ]
  }, { title: "Choose the auth strategy", tool_use_id: QUESTION_ID })
];

export const questionResolution: ProtocolLine[] = [
  toolResult(QUESTION_ID, "User selected: Stack Auth; Billing, Team settings"),
  sessionState("running"),
  ...streamText(
    MSG,
    2,
    "Stack Auth it is — I'll reuse the existing session cookie so the dashboard inherits the web app's login, and gate **Billing** and **Team settings** behind the middleware while leaving analytics and the status page public."
  ),
  statusLine(null),
  resultLine({ result: "Auth strategy confirmed: Stack Auth, gating Billing and Team settings." })
];

const SINGLE_MSG = "msg_question_single";

export const questionMultiFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine(),
  userLine("Should I delete the legacy migration folder?"),
  sessionState("running"),
  messageStart(SINGLE_MSG),
  ...streamText(SINGLE_MSG, 0, "That folder is referenced by two scripts, so I want to confirm first."),
  messageStop(),
  sessionState("requires_action"),
  canUseTool("req-question-2", "AskUserQuestion", {
    questions: [
      {
        question: "Delete `db/legacy-migrations/`?",
        header: "Confirm deletion",
        multiSelect: false,
        options: [
          { label: "Delete it", description: "Removes 34 files. The rollback script stops working." },
          { label: "Archive instead", description: "Move to `db/.archive/` and drop it from the build." },
          { label: "Leave it alone", description: "No change; I'll continue with the rest of the task." }
        ]
      }
    ]
  }, { title: "Confirm deletion", tool_use_id: "toolu_req-question-2" })
];
