# Observed wire notes versus `harness-design-protocol.md`

All observations below come from the fixture files in this directory and Claude Code 2.1.227. Decoder and state-machine behavior should follow the observed wire even where the design appendix used a narrower sketch.

## Loud surprises

### 1. Interrupt is a terminal error result, not a normal completed result

`controls.jsonl` captured this exact control acknowledgment payload:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"fixture-interrupt","response":{"still_queued":[]}}}
```

There is no `interrupted: true` field. `still_queued` describes Claude Code's internal queue, as the design anticipated.

The authoritative terminal line is then:

- `type: "result"`
- `subtype: "error_during_execution"`
- `is_error: true`
- `terminal_reason: "aborted_streaming"`
- `stop_reason: null`
- `duration_api_ms: 0`
- zero aggregate token usage and empty `modelUsage`
- `errors: ["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"]`

The print-mode child exited with status 1 after emitting that complete result. Therefore:

- do not treat a successful interrupt `control_response` as turn completion;
- do not require an `end_turn` stop reason after interrupt;
- classify `aborted_streaming` as the observed user-interrupt terminal result for 2.1.227;
- a nonzero process exit after a complete interrupt result is not a missing-result protocol failure.

### 2. Control responses are intentionally inconsistent about an inner payload

The envelope is consistently:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"..."}}
```

but the optional inner `response` differs by subtype:

- `list_models` adds `response.models`.
- `set_permission_mode` adds `response.mode`.
- `interrupt` adds `response.still_queued`.
- `set_model`, `set_max_thinking_tokens`, and both `apply_flag_settings` calls returned success with **no inner `response` at all**.

The decoder must make the inner response optional. Option reconciliation cannot assume every mutating control echoes its applied value; observe subsequent `system.status`/`system.init` or retain the successfully requested value where the protocol provides no echo.

### 3. `system.init` capabilities are a small string array, not a feature object

Every captured `system.init` reports:

```json
["interrupt_receipt_v1","interrupt_cancel_queued_v1","msg_lifecycle_v1"]
```

Preserve unknown strings. Do not infer support for model, permission, thinking, effort, or fast controls solely from this array; those controls must be negotiated by request success/failure and model descriptors.

### 4. Complete top-level assistant lines are block snapshots, not necessarily one cumulative message

In thinking/tool captures, multiple top-level `assistant` lines can share one Messages API message ID while each line contains only the just-completed block:

1. an assistant line containing the completed thinking block;
2. later, another assistant line containing the tool-use block;
3. after tool execution, a new message ID for final text.

Also, the complete assistant line can arrive **before** that block's nested `content_block_stop`. Treat nested partials as drafts and reconcile by message ID + block identity/index; do not append every top-level assistant line as an independent conversational assistant turn.

### 5. Tool-result ordering races with stream termination

In `permission-ccx.jsonl`, the top-level `user`/`tool_result` line appears before the preceding nested `message_delta` and `message_stop`. In `permission-allow.jsonl`, it appears after them. The accumulator must not require `message_stop` before accepting a tool result.

## Other observed shape differences and additions

### Controls are accepted before `system.init`

`controls.jsonl` sends `list_models` immediately. Claude Code answers it before `system.init`; the init line is not emitted until the first user turn starts. Startup code may use an explicit `initialize`/control bootstrap and must not gate every control on having already received `system.init`.

### `list_models` entries are heterogeneous

Observed fields include:

- `value`, which is the string to send to `set_model`;
- `resolvedModel`, which may include a context suffix such as `claude-opus-5[1m]`;
- `displayName`, `description`;
- optional `promoListPrice`;
- optional `supportsEffort`, `supportedEffortLevels`;
- optional `supportsAdaptiveThinking`, `supportsFastMode`, `supportsAutoMode`.

Haiku had only the basic identity/description fields. Fable omitted `supportsFastMode`. Decode capability fields as optional, not default-true.

### Successful option changes can surface through later system events

After `set_permission_mode(plan)`, Claude emitted:

```json
{"type":"system","subtype":"status","status":null,"permissionMode":"plan",...}
```

After the control sequence, `system.init` reported resolved model `claude-opus-5[1m]`, `permissionMode: "plan"`, and `fast_mode_state: "on"`. A status line may therefore have `status: null` while carrying an option update.

### Thinking text may be empty while thinking is real

Current-model thinking fixtures contain:

- `content_block_start` with `{type:"thinking", thinking:"", signature:""}`;
- one or more `thinking_delta` frames whose `thinking` is an empty string and whose `estimated_tokens` is either an integer or `null`;
- a non-empty `signature_delta`;
- separate `system.thinking_tokens` events.

Empty thinking text is not absence of thinking and must not suppress the block or its token progress.

### `message_delta.usage` has fields not present in the design sketch

Thinking-enabled captures include:

```json
"output_tokens_details":{"thinking_tokens":...}
```

The field may be absent for a text-only turn. `message_delta` also carries `context_management.applied_edits` beside the nested event envelope.

### Result usage and model usage use different naming conventions

Root `result.usage` uses snake_case (`input_tokens`, `cache_read_input_tokens`, `server_tool_use`). `result.modelUsage[model]` uses camelCase (`inputTokens`, `cacheReadInputTokens`, `maxOutputTokens`, `canonicalModel`, `costUSD`). Preserve both independently.

Observed `maxOutputTokens` values are CLI-reported capabilities, not constants from the design document: existing Fable captures report `64000`; new Haiku captures report `32000`.

### Successful permission denial is still a successful overall session result

`permission-deny.jsonl` ends with:

- `subtype: "success"`
- `is_error: false`
- `terminal_reason: "completed"`
- `permission_denials` containing the denied tool call.

The denial itself appears as a `user` tool result with `is_error: true`. Do not promote a denied tool permission into a process/session failure.

### Root `tool_use_result` is a true union

Observed allow result:

```json
{"type":"create","filePath":"/tmp/...","content":"approved","structuredPatch":[],"originalFile":null,"userModified":false}
```

Observed deny result:

```json
"Error: User denied this operation."
```

The deny line also has `tool_result_meta`, an array containing `non_execution_kind: "permission-rule"`. The root field must remain arbitrary JSON, including a scalar string.

### Hook lifecycle has more than start/response

With `--include-hook-events`, `tool-turn.jsonl` includes `system` subtype `hook_progress` in addition to `hook_started` and `hook_response`. Direct PATH launches can emit multiple concurrent hook starts/responses. Hook IDs, names, event names, stdout/stderr, exit codes, and outcomes must remain typed-or-unknown rather than assuming one hook pair per turn.

### Resume preserves provider identity but per-run counters reset

`resume-first.jsonl` and `resume-second.jsonl` report the same session ID in both `system.init` and `result`. The resumed process does not replay the first run into stdout, and the second result reports `num_turns: 1`, not a cumulative 2. Treat `num_turns` as the current print invocation's count unless future evidence says otherwise.

### Top-level assistant stop reason remains null until later frames

Complete top-level `assistant.message.stop_reason` is null in these captures. The authoritative stop reason arrives in nested `message_delta` and the terminal `result`. Do not mark a turn finished from the complete assistant line alone.

## Launcher-specific observations

### ccx banner is raw stdout and invalid JSON by design

The first line of `ccx-banner.jsonl` is ANSI-dim text, not JSON. It survived byte-for-byte. A line reader must classify and retain it as a launcher notice, then continue parsing subsequent JSON objects.

### ccx explicit permission flags override its injected skip flag

`permission-ccx.jsonl` contains a real `can_use_tool` request despite ccx prepending `--dangerously-skip-permissions`. With the tested argument order, later `--permission-mode default --permission-prompt-tool stdio` wins in 2.1.227.

### ccx proxy-down failure has no protocol stdout

With `CCX_PROXY_URL=http://localhost:1`, ccx exits 1 with an ANSI-colored stderr diagnostic and empty stdout. Classify this from spawn/exit/stderr, not as malformed or missing Claude JSON.

### Missing launcher has no child exit code

A nonexistent executable raises OS `ENOENT` before a process exists. The harness should surface a launcher-resolution/spawn error directly; waiting for stdout EOF, stderr, or a result line is incorrect.
