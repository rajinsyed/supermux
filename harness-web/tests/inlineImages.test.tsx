import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, render } from "@testing-library/react";
import type { ImageBlock, Turn } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { BlockView } from "../src/ui/transcript/BlockView";
import { TurnView } from "../src/ui/transcript/TurnView";

afterEach(cleanup);

describe("inline image rendering", () => {
  test("renders validated bytes as a lazy non-draggable data image", () => {
    const block: ImageBlock = {
      kind: "image",
      key: "image:1",
      mediaType: "image/webp",
      dataBase64: "UklGRg=="
    };
    const { container } = render(<BlockView block={block} />);
    const image = container.querySelector("img.block-image");

    expect(image?.getAttribute("src")).toBe("data:image/webp;base64,UklGRg==");
    expect(image?.getAttribute("alt")).toBe("");
    expect(image?.getAttribute("loading")).toBe("lazy");
    expect(image?.getAttribute("decoding")).toBe("async");
    expect(image?.getAttribute("draggable")).toBe("false");
  });

  test("keeps image output visible when the producing turn folds its work", () => {
    const image: ImageBlock = {
      kind: "image",
      key: "image:folded",
      mediaType: "image/png",
      dataBase64: "iVBORw0KGgo="
    };
    const turn: Turn = {
      id: "turn:folded-image",
      seq: 1,
      startedAtMs: 1000,
      endedAtMs: 1200,
      state: "complete",
      blocks: [
        {
          kind: "tool",
          key: "tool:image",
          toolUseId: "toolu_image",
          messageId: "msg-image",
          name: "Read",
          input: {},
          children: [],
          status: "success",
          streaming: false,
          inputComplete: true,
          startedAtMs: 1000,
          endedAtMs: 1100
        },
        image
      ],
      folded: true,
      revision: 0
    };
    const { container } = render(
      <CopyProvider dict={undefined}>
        <TurnView turn={turn} />
      </CopyProvider>
    );

    expect(container.querySelector("img.block-image")).not.toBeNull();
    expect(container.querySelector(".tool-card")).toBeNull();
  });
});
