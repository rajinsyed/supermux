# harness-web

The web UI for the Supermux Claude harness pane (`claudeHarness`). Standalone, supermux-owned,
offline: React 19 + TypeScript bundled by esbuild into a single self-contained `index.html` that
runs from `file://` inside a WKWebView. No CDN, no runtime network fetches, no vite.

## Commands

```bash
bun install
bun run dev        # dev server on http://127.0.0.1:5199 with the mock bridge
bun run build      # production bundle → dist/index.html
bun test           # reducer tests against fixtures
bun run typecheck  # tsc --noEmit
```

## Architecture

| Path | Responsibility |
| --- | --- |
| `src/protocol/types.ts` | Typed Claude stream-json protocol per CONTRACT.md |
| `src/model/transcript.ts` | Pure reducer: protocol lines → transcript model |
| `src/model/blocks.ts` | Block tree read/write helpers (paths, eviction, settling) |
| `src/model/systemLines.ts` | `system/*` subtypes (init, status, tasks, compact, retry) |
| `src/model/turns.ts` | Turn lifecycle, queue promotion, reset, banners |
| `src/model/toolStatus.ts` | Failure sniffing and TodoWrite extraction |
| `src/model/store.ts` | `useSyncExternalStore` store, rAF batching, per-turn subscriptions |
| `src/bridge.ts` | `window.supermuxHarness.receiveBatch` + `callNative` envelope |
| `src/copyKeys.ts` | Every user-visible string, with English defaults (source for `supermux.harness.*`) |
| `src/ui/**` | Components: header, transcript, tool cards, permission/plan/question, composer |
| `src/dev/**` | Mock bridge, fixtures, scenario routing (dev only — never in the prod bundle) |

The reducer is pure and side-effect free: `applyLine(model, index, line, nowMs)`. The `index`
carries mutable bookkeeping (seen uuids, tool locations, stream message ids) so replaying the same
uuid twice is a no-op — this is what absorbs the CLI's ordering quirk where an `assistant` frame
arrives before its `content_block_stop`.

`src/main.tsx` is the production entrypoint (native bridge only). `src/dev/main.tsx` is the dev
entrypoint and is the only thing that pulls in fixtures, so `bun run build` never ships them.

## Bridge contract

JS → Swift via `window.webkit.messageHandlers.supermuxHarness.postMessage({id, method, params})`,
replying `{ok:true,value}` or `{ok:false,error:{code,userMessage}}`. Methods: `harness.context`,
`listSessions`, `loadSessionHistory`, `start`, `send`, `interrupt`, `cancelQueued`, `stop`,
`setModel`, `setPermissionMode`, `respondPermission`, `renameSession`, `getContextUsage`,
`fileSuggestions`, `pickFiles`, `openFile`, `copyText`, `notify`, `saveDraft`.

Swift → JS via one batched `window.supermuxHarness.receiveBatch([...])` call. Envelope kinds:
`protocol` (verbatim stdout line), `runStarted`, `runExited`, `stderr`, `theme`.

The scroll container carries `class="harness-scroll"` — the native scroll-wheel bridge targets it.

## Theme

Native pushes the 14-field `AgentSessionWebTheme` dict; `src/ui/theme.ts` derives the full scale
(hover/active/sunken elevations, code and terminal backgrounds, diff and syntax colors, Claude
terracotta accents) onto CSS custom properties. `pageBackground` may be the literal string
`"transparent"` for Ghostty transparency, so popovers derive their own opaque background rather
than inheriting a translucent surface.

## Localization

`src/copyKeys.ts` exports `copyDefaults` — the complete key → English map. The Swift side generates
`supermux.harness.*` entries in `Resources/Localizable.xcstrings` from it and delivers the resolved
dict in `harness.context.copy`. Components read strings through `useCopy()`; `{placeholder}` tokens
are interpolated by `format()`. No component hard-codes user-visible English.

## Dev scenarios

`http://127.0.0.1:5199/?scenario=<name>&theme=dark|light&speed=instant|fast|realtime`

`empty`, `nocli`, `rich`, `streaming`, `thinking`, `permission`, `question`, `plan`, `todos`,
`subagents`, `interrupt`, `errors`, `compact`, `queue`, `longform`, `sessions`, `resume`,
`rewind`, `binary`, `firstopen`, `crash`.

Two flags refine `rewind`, because the file half of a rewind can fail in two different places:

| Flag | What the CLI does | What the pane must show |
| --- | --- | --- |
| `&degraded=1` | the dry run answers `canRewind:false` | no checkbox to arm, and the reason stated up front |
| `&restorefail=1` | the dry run promises a restore, the real `rewind_files` then refuses | the conversation still rewinds, and the note says the files did not |

`rich` replays the real 202-line CLI trace in `src/dev/fixtures/rich-session.jsonl`. `streaming`
freezes that replay mid-stream so screenshots capture the live UI. `permission`, `question`, and
`plan` are interactive: answering the card advances the scripted follow-up, so Allow → the tool
actually runs.

`src/dev/fixtures/richSessionRaw.ts` is generated from the `.jsonl` by
`bun run scripts/generate-fixture.ts` (the jsonl stays checked in as the source of truth).
