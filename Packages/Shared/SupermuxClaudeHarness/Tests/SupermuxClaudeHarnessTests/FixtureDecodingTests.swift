import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// Drives the classifier + decoder over every captured CLI fixture and asserts
/// the typed output matches the wire notes. Fixtures are verbatim captures
/// from Claude Code 2.1.227 — never hand-written JSON.
struct FixtureDecodingTests {
    @Test func simpleTurnDecodesFully() throws {
        let fixture = try FixtureSupport.decode("simple-turn.jsonl")
        #expect(fixture.unknownLines.isEmpty)
        #expect(fixture.malformed.isEmpty)
        #expect(fixture.launcherNotices.isEmpty)

        let initialization = try #require(fixture.initializations.first)
        #expect(initialization.sessionID == "b9fdc655-a2a4-4530-9710-1b99de9eb03d")
        #expect(initialization.tools.contains("Bash"))
        #expect(initialization.capabilities.contains("interrupt_receipt_v1"))

        let textDeltas = fixture.streamEvents.compactMap { envelope -> String? in
            if case .contentBlockDelta(_, .text(let text)) = envelope.event { return text }
            return nil
        }
        #expect(textDeltas.count == 2)

        let result = try #require(fixture.results.first)
        #expect(result.subtype == "success")
        #expect(result.isError == false)
        #expect(result.terminalReason == "completed")
        #expect(result.stopReason == "end_turn")
        #expect(result.totalCostUSD == 0.01121945)
        #expect(result.numTurns == 1)
        let usage = try #require(result.usage)
        #expect(usage.inputTokens == 3)
        #expect(usage.outputTokens == 8)
        #expect(usage.cacheCreationInputTokens == 7577)
        #expect(usage.cacheReadInputTokens == 17052)
        #expect(usage.serviceTier == "standard")
        let model = try #require(result.modelUsage["claude-haiku-4-5-20251001"])
        #expect(model.costUSD == 0.01121945)
        #expect(model.contextWindow == 200_000)
        #expect(model.maxOutputTokens == 32000)
        #expect(model.canonicalModel == "claude-haiku-4-5")
        #expect(model.provider == "firstParty")
    }

    @Test func thinkingTurnCarriesThinkingAndSignature() throws {
        let fixture = try FixtureSupport.decode("thinking-turn.jsonl")
        #expect(fixture.unknownLines.isEmpty)

        var thinkingDeltas = 0
        var signatureDeltas = 0
        for envelope in fixture.streamEvents {
            if case .contentBlockDelta(_, let delta) = envelope.event {
                if case .thinking = delta { thinkingDeltas += 1 }
                if case .signature = delta { signatureDeltas += 1 }
            }
        }
        #expect(thinkingDeltas == 2)
        #expect(signatureDeltas == 1)

        // system.thinking_tokens progress lines are typed.
        let progress = fixture.systemEvents.filter {
            if case .thinkingTokens = $0 { return true } else { return false }
        }
        #expect(!progress.isEmpty)

        // A complete assistant line carries the thinking block. Observed wire:
        // its text may be EMPTY while the signature is real — empty thinking
        // is not absence of thinking.
        let hasSignedThinkingBlock = fixture.assistants.contains { envelope in
            envelope.message.content.contains {
                if case .thinking(_, let signature) = $0 {
                    return signature?.isEmpty == false
                }
                return false
            }
        }
        #expect(hasSignedThinkingBlock)

        let result = try #require(fixture.results.first)
        #expect(result.modelUsage.keys.contains("claude-fable-5"))
    }

    @Test func toolTurnReassemblesInputJSONDeltas() throws {
        let fixture = try FixtureSupport.decode("tool-turn.jsonl")
        #expect(fixture.unknownLines.isEmpty)

        // Accumulate input_json_delta fragments per block index.
        var fragments: [String] = []
        for envelope in fixture.streamEvents {
            if case .contentBlockDelta(_, .inputJSON(let fragment)) = envelope.event {
                fragments.append(fragment)
            }
        }
        #expect(fragments.count == 4)
        let assembled = fragments.joined()
        let assembledValue = try JSONDecoder().decode(
            ClaudeJSONValue.self, from: Data(assembled.utf8)
        )

        // The authoritative tool_use input on the complete assistant line
        // must equal the reassembled streamed input.
        var authoritativeInput: ClaudeJSONValue?
        var toolName: String?
        for envelope in fixture.assistants {
            for block in envelope.message.content {
                if case .toolUse(_, let name, let input, _) = block {
                    authoritativeInput = input
                    toolName = name
                }
            }
        }
        #expect(toolName == "Bash")
        #expect(authoritativeInput == assembledValue)
        #expect(authoritativeInput?["command"]?.stringValue == "echo ok")

        // The tool result arrives as a user line with a preserved root
        // tool_use_result object.
        let toolResultUser = try #require(fixture.users.first { $0.toolUseResult != nil })
        #expect(toolResultUser.toolUseResult?["stdout"]?.stringValue == "ok")
        let hasToolResultBlock = toolResultUser.message.content.contains {
            if case .toolResult = $0 { return true } else { return false }
        }
        #expect(hasToolResultBlock)

        // hook_progress decodes as a typed hook event.
        let progress = fixture.systemEvents.filter {
            if case .hookProgress = $0 { return true } else { return false }
        }
        #expect(!progress.isEmpty)
    }

    @Test func controlsFixtureDecodesResponsesAndInterruptResult() throws {
        let fixture = try FixtureSupport.decode("controls.jsonl")
        #expect(fixture.unknownLines.isEmpty)

        // list_models carries an inner payload with heterogeneous models.
        let listResponse = try #require(
            fixture.controlResponses.first { $0.requestID == "fixture-list-models" }
        )
        #expect(listResponse.isSuccess)
        let models = ClaudeModelDescriptor.models(from: listResponse.payload)
        #expect(!models.isEmpty)
        let defaultModel = try #require(models.first { $0.value == "default" })
        #expect(defaultModel.resolvedModel == "claude-opus-5[1m]")
        #expect(defaultModel.supportsEffort == true)
        #expect(!defaultModel.supportedEffortLevels.isEmpty)

        // set_model succeeded with NO inner payload — must stay decodable.
        let setModel = try #require(
            fixture.controlResponses.first { $0.requestID == "fixture-set-model" }
        )
        #expect(setModel.isSuccess)
        #expect(setModel.payload == nil)

        // permission mode echoes its mode (decode-tolerance only; the harness
        // never sends set_permission_mode).
        let setMode = try #require(
            fixture.controlResponses.first { $0.requestID == "fixture-set-permission-plan" }
        )
        #expect(setMode.payload?["mode"]?.stringValue == "plan")

        // interrupt acknowledges with still_queued.
        let interrupt = try #require(
            fixture.controlResponses.first { $0.requestID == "fixture-interrupt" }
        )
        #expect(interrupt.payload?["still_queued"]?.arrayValue?.isEmpty == true)

        // The terminal result after interrupt is the observed error shape.
        let result = try #require(fixture.results.first)
        #expect(result.subtype == "error_during_execution")
        #expect(result.isError == true)
        #expect(result.terminalReason == "aborted_streaming")
        #expect(result.stopReason == nil)
        #expect(result.durationAPIMs == 0)
        #expect(result.modelUsage.isEmpty)
        #expect(result.errors.count == 1)
    }

    @Test func resumePreservesProviderSessionIdentity() throws {
        let first = try FixtureSupport.decode("resume-first.jsonl")
        let second = try FixtureSupport.decode("resume-second.jsonl")

        let firstInit = try #require(first.initializations.first)
        let secondInit = try #require(second.initializations.first)
        #expect(firstInit.sessionID == "2de2246f-0b7f-4d39-b7d4-087d163cdeab")
        #expect(firstInit.sessionID == secondInit.sessionID)

        let firstResult = try #require(first.results.first)
        let secondResult = try #require(second.results.first)
        #expect(firstResult.sessionID == secondResult.sessionID)
        // num_turns resets per print invocation rather than accumulating.
        #expect(firstResult.numTurns == 1)
        #expect(secondResult.numTurns == 1)
    }

    @Test func ccxBannerClassifiesAsLauncherNoticeNotError() throws {
        let fixture = try FixtureSupport.decode("ccx-banner.jsonl")
        #expect(fixture.launcherNotices.count == 1)
        let notice = try #require(fixture.launcherNotices.first)
        // ANSI escapes stripped; content preserved.
        #expect(notice.contains("ccx"))
        #expect(!notice.contains("\u{1B}"))
        #expect(fixture.malformed.isEmpty)
        // The rest of the stream still decodes.
        #expect(!fixture.initializations.isEmpty)
        #expect(!fixture.results.isEmpty)
    }

    @Test(arguments: ["permission-allow.jsonl", "permission-deny.jsonl", "permission-ccx.jsonl"])
    func permissionFixturesDecodeTolerantlyAsInertControlRequests(name: String) throws {
        // Permissions are always skipped in this harness; these fixtures stay
        // in the corpus purely as decode-tolerance inputs. They must classify
        // as inbound control_request without crashing — nothing more.
        let fixture = try FixtureSupport.decode(name)
        let inbound = fixture.inboundControlRequests.filter { $0.subtype == "can_use_tool" }
        #expect(inbound.count == 1)
        #expect(inbound.first?.requestID != nil)
        #expect(!fixture.results.isEmpty)
    }

    @Test func permissionDenyKeepsOverallResultSuccessful() throws {
        let fixture = try FixtureSupport.decode("permission-deny.jsonl")
        let result = try #require(fixture.results.first)
        #expect(result.subtype == "success")
        #expect(result.isError == false)
        #expect(result.terminalReason == "completed")
        #expect(result.permissionDenials?.arrayValue?.isEmpty == false)

        // Root tool_use_result is a scalar string on the denied execution.
        let denied = fixture.users.first { $0.toolUseResult?.stringValue != nil }
        #expect(denied != nil)
    }

    @Test func errorFixturesAreNotProtocolOutput() throws {
        // ANSI stderr from ccx proxy-down classifies as launcher notice text,
        // never as malformed protocol JSON.
        let lines = try FixtureSupport.rawLines(
            "ccx-proxy-down.txt", subdirectory: "Fixtures/errors"
        )
        for line in lines {
            let classification = ClaudeLineClassifier.classify(line)
            switch classification {
            case .launcherNotice, .empty:
                break
            default:
                Issue.record("unexpected classification \(classification)")
            }
        }
    }

    @Test func oversizedLineIsBoundedAndDiscarded() {
        let big = Data(repeating: UInt8(ascii: "a"), count: 128)
        let classification = ClaudeLineClassifier.classify(big, maxBytes: 64)
        #expect(classification == .tooLarge(byteCount: 128))
    }

    @Test func malformedJSONLineClassifies() {
        let classification = ClaudeLineClassifier.classify(#"{"type": "system", "#)
        guard case .malformedJSON = classification else {
            Issue.record("expected malformedJSON, got \(classification)")
            return
        }
    }
}
