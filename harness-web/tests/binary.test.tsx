import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { HarnessBridgeError } from "../src/bridge";
import type { BinarySetting, CliStatus } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { NoCliState } from "../src/ui/empty/EmptyStates";
import { BinaryDialog } from "../src/ui/settings/BinaryDialog";

afterEach(cleanup);

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

const RESOLVED: BinarySetting = {
  resolvedPath: "/opt/homebrew/bin/claude",
  version: "2.1.233"
};

const OVERRIDDEN: BinarySetting = {
  resolvedPath: "/Users/dev/.local/bin/ccx",
  overridePath: "/Users/dev/.local/bin/ccx",
  version: "2.1.233-ccx"
};

/**
 * The reported need: a wrapper script at ~/.local/bin/ccx that points claude at
 * a local proxy. PATH resolution can never find it, so without a settable
 * override the pane is simply unusable for that user.
 */
describe("the binary dialog", () => {
  test("shows what resolution actually settled on, read-only", async () => {
    const { container } = mount(
      <BinaryDialog onClose={() => {}} load={async () => RESOLVED} save={async () => RESOLVED} />
    );
    await settle();
    expect(container.querySelector(".binary-path")!.textContent).toBe("/opt/homebrew/bin/claude");
    expect(screen.getByText("Version 2.1.233")).toBeDefined();
  });

  test("prefills the field with the stored override", async () => {
    mount(
      <BinaryDialog onClose={() => {}} load={async () => OVERRIDDEN} save={async () => OVERRIDDEN} />
    );
    await settle();
    expect((screen.getByRole("textbox") as HTMLInputElement).value).toBe("/Users/dev/.local/bin/ccx");
  });

  test("saving sends the typed path", async () => {
    const saved: Array<string | undefined> = [];
    mount(
      <BinaryDialog
        onClose={() => {}}
        load={async () => RESOLVED}
        save={async (path) => {
          saved.push(path);
          return OVERRIDDEN;
        }}
      />
    );
    await settle();
    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "/Users/dev/.local/bin/ccx" }
    });
    fireEvent.click(screen.getByText("Save"));
    await settle();
    expect(saved).toEqual(["/Users/dev/.local/bin/ccx"]);
    expect(screen.getByText("Saved")).toBeDefined();
  });

  test("Enter in the field saves too, so the obvious gesture works", async () => {
    const saved: Array<string | undefined> = [];
    mount(
      <BinaryDialog
        onClose={() => {}}
        load={async () => RESOLVED}
        save={async (path) => {
          saved.push(path);
          return OVERRIDDEN;
        }}
      />
    );
    await settle();
    const field = screen.getByRole("textbox");
    fireEvent.change(field, { target: { value: "/Users/dev/.local/bin/ccx" } });
    fireEvent.keyDown(field, { key: "Enter" });
    await settle();
    expect(saved).toEqual(["/Users/dev/.local/bin/ccx"]);
  });

  test("clearing sends undefined rather than an empty string", async () => {
    const saved: Array<string | undefined> = [];
    mount(
      <BinaryDialog
        onClose={() => {}}
        load={async () => OVERRIDDEN}
        save={async (path) => {
          saved.push(path);
          return RESOLVED;
        }}
      />
    );
    await settle();
    fireEvent.click(screen.getByText("Clear"));
    await settle();
    expect(saved).toEqual([undefined]);
    expect((screen.getByRole("textbox") as HTMLInputElement).value).toBe("");
  });

  test("a rejected path reports the native message in place", async () => {
    // The whole point of a free-text path field is that the path may be wrong.
    // Closing on a silent no-op would leave the user certain they had saved it.
    mount(
      <BinaryDialog
        onClose={() => {}}
        load={async () => RESOLVED}
        save={async () => {
          throw new HarnessBridgeError({
            code: "binary_invalid",
            userMessage: "/Users/dev/nope is not executable."
          });
        }}
      />
    );
    await settle();
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "/Users/dev/nope" } });
    fireEvent.click(screen.getByText("Save"));
    await settle();
    expect(screen.getByRole("alert").textContent).toBe("/Users/dev/nope is not executable.");
    expect(screen.queryByText("Saved")).toBeNull();
  });

  test("it says the change lands on the next start, not immediately", async () => {
    // Changing the binary does not kill a running session; a dialog that stayed
    // silent about that invites the user to expect it did.
    mount(
      <BinaryDialog onClose={() => {}} load={async () => RESOLVED} save={async () => RESOLVED} />
    );
    await settle();
    expect(screen.getByText("Applies the next time the session starts.")).toBeDefined();
  });

  test("Escape closes it", async () => {
    let closed = 0;
    const { container } = mount(
      <BinaryDialog
        onClose={() => {
          closed += 1;
        }}
        load={async () => RESOLVED}
        save={async () => RESOLVED}
      />
    );
    await settle();
    fireEvent.keyDown(container.querySelector('[role="dialog"]')!, { key: "Escape" });
    expect(closed).toBe(1);
  });
});

describe("the no-CLI screen offers the override", () => {
  const status: CliStatus = { available: false, error: "spawn claude ENOENT" };

  test("a user who already has a wrapper is not told to npm install and nothing else", () => {
    let opened = 0;
    mount(
      <NoCliState
        status={status}
        onRetry={() => {}}
        onSetBinary={() => {
          opened += 1;
        }}
      />
    );
    fireEvent.click(screen.getByText("Point at a binary…"));
    expect(opened).toBe(1);
  });
});
