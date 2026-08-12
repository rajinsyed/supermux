public import SupermuxMobileCore

/// Response aliases for the `mobile.supermux.claude.*` methods.
///
/// The Claude harness answers with the shared wire DTOs verbatim, so there is
/// no phone-only response layer to drift from the contract. These aliases
/// exist so call sites read as `…Response` like every other supermux method
/// family, and so the request → response pairing is stated in one place.

/// `sessions.list` → every retained session plus the registry's state version.
public typealias SupermuxClaudeSessionsListResponse = SupermuxClaudeSessionsDTO

/// `session.create` / `.get` / `.resume` → one authoritative snapshot, plus a
/// redacted `stderr_excerpt` when the session came back failed (this is where
/// a ccx DroidProxy preflight failure surfaces).
public typealias SupermuxClaudeSessionResponse = SupermuxClaudeSessionResultDTO

/// `session.end` / `.delete` / `interrupt` → an acknowledgement.
public typealias SupermuxClaudeAcknowledgementResponse = SupermuxClaudeAcknowledgementDTO

/// `send` → whether the prompt was queued Mac-side, and where in the queue.
public typealias SupermuxClaudeSendResponse = SupermuxClaudeSendResultDTO

/// `set_option` → the RECONCILED value the Mac observed after applying it.
public typealias SupermuxClaudeSetOptionResponse = SupermuxClaudeSetOptionResultDTO

/// `options` → model catalog, effort levels, slash commands, launcher availability.
public typealias SupermuxClaudeOptionsResponse = SupermuxClaudeOptionsDTO

/// `history` → one page of transcript messages, oldest first.
public typealias SupermuxClaudeHistoryResponse = SupermuxClaudeHistoryPageDTO

/// `tool_payload` → one bounded chunk of an untruncated tool body.
public typealias SupermuxClaudeToolPayloadResponse = SupermuxClaudeToolPayloadChunkDTO

/// `watch` → the lease state after acquiring, renewing, or releasing.
public typealias SupermuxClaudeWatchResponse = SupermuxClaudeWatchResultDTO
