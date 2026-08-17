import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { SlashCommandDescriptor } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { Composer } from "../src/ui/composer/Composer";

afterEach(cleanup);

const COMMANDS: SlashCommandDescriptor[] = [
  { name: "compact", description: "Summarize the conversation" },
  { name: "context", description: "Show context usage" },
  { name: "clear", description: "Clear the conversation" }
];

interface Harness {
  draft(): string;
  sent: string[];
  rerender(next: string): void;
}

function mount(options: { disabled?: boolean } = {}): Harness {
  const sent: string[] = [];
  let draft = "";
  const view = (text: string) => (
    <CopyProvider dict={undefined}>
      <Composer
        disabled={options.disabled ?? false}
        running={false}
        awaitingPermission={false}
        planPending={false}
        onPlanImplement={() => {}}
        onPlanRefine={() => {}}
        onPlanKeepPlanning={() => {}}
        queued={[]}
        commands={COMMANDS}
        permissionMode="default"
        draft={text}
        onDraftChange={(next) => {
          draft = next;
          rendered.rerender(view(next));
        }}
        onSend={(text) => sent.push(text)}
        onInterrupt={() => {}}
        onCancelQueued={() => {}}
        onCyclePermissionMode={() => {}}
        fetchFileSuggestions={async () => ["src/ui/App.tsx"]}
        onPickFiles={async () => []}
      />
    </CopyProvider>
  );
  const rendered = render(view(""));
  return {
    draft: () => draft,
    sent,
    rerender: (next: string) => {
      draft = next;
      rendered.rerender(view(next));
    }
  };
}

/** Typing goes through the real change handler so the caret tracks like a browser's. */
function type(text: string): void {
  const input = screen.getByRole("textbox") as HTMLTextAreaElement;
  act(() => {
    fireEvent.change(input, { target: { value: text, selectionStart: text.length } });
  });
}

/**
 * The textarea's own value matches the popover row's text, so every lookup is
 * scoped to the listbox — otherwise the query resolves to the draft.
 */
async function popoverRow(label: string): Promise<HTMLElement> {
  const list = await screen.findByRole("listbox");
  const row = Array.from(list.querySelectorAll<HTMLElement>(".popover-label")).find(
    (node) => node.textContent === label
  );
  if (!row) throw new Error(`no popover row for ${label}`);
  return row;
}

describe("slash-command popover completes a real command", () => {
  test("accepting with Enter keeps the leading slash", async () => {
    const harness = mount();
    type("/co");
    await popoverRow("/compact");

    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    // Without the sigil the CLI reads "compact " as prose and the model answers
    // it, instead of running the slash command.
    expect(harness.draft()).toBe("/compact ");
    expect(harness.draft().startsWith("/")).toBe(true);
  });

  test("accepting by clicking a row keeps it too", async () => {
    const harness = mount();
    type("/compact");
    const row = await popoverRow("/compact");

    fireEvent.mouseDown(row);

    expect(harness.draft()).toBe("/compact ");
  });

  test("the completed command is what gets sent", async () => {
    const harness = mount();
    type("/context");
    await popoverRow("/context");
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    // The completion repositions the caret in a rAF; let it land so the popover
    // is genuinely closed and the next Enter submits rather than re-completing.
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    expect(harness.sent).toEqual(["/context"]);
  });

  test("a mention still carries its own sigil", async () => {
    const harness = mount();
    type("look at @App");
    await popoverRow("src/ui/App.tsx");

    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    expect(harness.draft()).toBe("look at @src/ui/App.tsx ");
  });

  test("a trigger with no matches says so instead of vanishing", async () => {
    mount();
    type("/zzzz");
    expect(await screen.findByText("No matching commands")).toBeDefined();
  });
});

describe("composer with no CLI", () => {
  test("the placeholder points at the fix rather than inviting a message", () => {
    mount({ disabled: true });
    const input = screen.getByRole("textbox") as HTMLTextAreaElement;
    expect(input.placeholder).toBe("Install the Claude Code CLI to start");
    expect(input.disabled).toBe(true);
  });
});
