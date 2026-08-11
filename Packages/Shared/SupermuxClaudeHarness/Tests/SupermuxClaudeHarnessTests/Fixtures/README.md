# Claude Code 2.1.227 stream-json fixtures

These fixtures were captured from real local processes on 2026-08-11/12. They are not hand-written protocol examples.

## Binaries

- `claude`: Claude Code `2.1.227 (Claude Code)`, invoked through the `claude` command found on `PATH`. At capture time that command resolved to `/var/folders/vp/kqdt2d2n2pl76rkt7q_lfr2r0000gn/T/cmux-cli-shims/BB9AFB6D-7388-43BF-95FA-8E2B8651556C/claude`, which delegates to the installed Claude Code binary at `/Users/syedrajin/.local/bin/claude`.
- `ccx`: `/Users/syedrajin/.local/bin/ccx`, whose delegated Claude Code binary reported `2.1.227 (Claude Code)`.
- Working directory for newly captured turns: `/tmp/supermux-claude-harness-fixtures` (reported by macOS/Swift/Foundation paths as `/private/tmp/supermux-claude-harness-fixtures` on the wire).
- Existing permission captures used `/tmp/ccx-probe` (reported as `/private/tmp/ccx-probe`).

No field names, object shapes, UUIDs, signatures, absolute paths, ANSI bytes, or model metadata were scrubbed. No assistant message was truncated. Empty lines at the end of the three pre-existing permission files were removed; their protocol lines are otherwise unchanged.

## Common invocation

The reusable driver is `capture_fixtures.py`. Its turn sessions use:

```text
-p
--input-format stream-json
--output-format stream-json
--include-partial-messages
--include-hook-events
--verbose
--permission-prompt-tool stdio
--replay-user-messages
```

Run all newly generated captures with:

```sh
python3 capture_fixtures.py all
```

The script also supports `simple`, `thinking`, `tool`, `controls`, `resume`, and a reusable `permission` mode.

## Corpus

| File | Capture procedure |
|---|---|
| `simple-turn.jsonl` | Launched `claude` with `--model haiku --effort low --permission-mode default`. Before beginning the captured turn, the driver sent `set_max_thinking_tokens` with `0`; Claude Code otherwise emitted thinking blocks even for Haiku. The capture window then began and contains the complete unedited turn from `system.init`/turn hooks through `result`. The turn has only a text content block and includes `message_start`, `content_block_delta(text_delta)`, `content_block_stop`, `message_delta`, and `message_stop`. |
| `thinking-turn.jsonl` | Launched `claude` with `--model claude-fable-5[1m] --effort high --permission-mode default`; prompt: `Think hard about 27*43, then answer with the product and one short verification sentence. Use no tools.` Contains real `thinking_delta` and `signature_delta` frames followed by text. |
| `tool-turn.jsonl` | Launched `claude` with `--dangerously-skip-permissions --model haiku --effort low`; prompt required Bash to run exactly `echo ok`. Contains streamed `tool_use` input via `input_json_delta`, the complete assistant tool-use line, the emitted `user`/`tool_result` line, hook lifecycle events, and the final assistant/result. |
| `permission-allow.jsonl` | Copied from `/tmp/ccx-probe/capture-claude-allow.jsonl`, created by `/tmp/ccx-probe/capture_permission.py claude allow`. The driver answered the real `can_use_tool` request with `behavior: allow` and the original input as `updatedInput`. |
| `permission-deny.jsonl` | Copied from `/tmp/ccx-probe/capture-claude-deny.jsonl`, created by `/tmp/ccx-probe/capture_permission.py claude deny`. The driver answered with `behavior: deny` and `User denied this operation.` |
| `permission-ccx.jsonl` | Copied from `/tmp/ccx-probe/capture-ccx-allow.jsonl`, created with `/Users/syedrajin/.local/bin/ccx` while it carried a since-reverted patch that suppressed its `--dangerously-skip-permissions` when the caller passed permission flags. With the stock ccx (and in the harness generally) permissions are always skipped and no `can_use_tool` request is ever emitted; this file is retained purely as a decode-tolerance input for inbound `control_request` lines. |
| `controls.jsonl` | One live `claude` process. The driver sent, in order, `list_models`, `set_model` using the returned `default` model value, `set_permission_mode` to `plan`, `set_max_thinking_tokens` to `4096`, `apply_flag_settings` with `effortLevel: high`, `apply_flag_settings` with `fastMode: true`, then `interrupt` during an active long generation. To retain request/response pairs, this is the one mixed-direction fixture: exact compact JSON request lines written to stdin are interleaved at send time with verbatim stdout lines. |
| `resume-first.jsonl` | Fresh `claude` process with an explicit generated `--session-id`, `--model haiku --effort low`; one turn, then stdin close and process exit. |
| `resume-second.jsonl` | New process launched with `--resume <session_id from resume-first>` and one additional turn. Both `system.init` and `result` report the same provider session ID as the first run. |
| `resume.jsonl` | Byte-for-byte concatenation of `resume-first.jsonl` and `resume-second.jsonl` for tests that want a single corpus. The split files remain the preferred per-process fixtures. |
| `ccx-banner.jsonl` | Raw copy of the ccx permission capture, including its first non-JSON stdout line with literal ANSI escape bytes: `ccx → saved default model  via http://localhost:8317`. It is intentionally not valid JSONL on line 1; the line framer must classify it as a launcher notice and continue. |
| `errors/ccx-proxy-down.txt` | Ran `CCX_PROXY_URL=http://localhost:1 /Users/syedrajin/.local/bin/ccx -p --output-format stream-json --input-format stream-json --include-partial-messages --verbose` with closed stdin. Captures exit code, empty stdout, and exact ANSI-colored stderr. |
| `errors/bad-launcher.txt` | Documents the actual Python/POSIX spawn failure from attempting `/tmp/supermux-claude-harness-fixtures/nonexistent-claude-launcher`: `FileNotFoundError`, errno 2 (`ENOENT`). This failure happens before a child process exists, so no protocol stdout/stderr/result can exist. |

## ccx permission precedence verdict (historical)

Probed against Claude Code 2.1.227 with the **stock** ccx: an earlier `--dangerously-skip-permissions` **wins** over later `--permission-mode`/`--permission-prompt-tool` arguments (the session reports `permissionMode: "bypassPermissions"` and no `can_use_tool` is emitted). `permission-ccx.jsonl` was captured while ccx carried a temporary, since-reverted patch that dropped the skip flag when permission flags were passed. None of this matters to the shipped harness — permissions are always skipped by design — but the precedence fact is recorded here so nobody re-derives it.
