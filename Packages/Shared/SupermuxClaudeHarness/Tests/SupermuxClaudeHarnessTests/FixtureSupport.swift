import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// Loads captured CLI fixtures and classifies/decodes every line.
enum FixtureSupport {
    struct DecodedFixture {
        var lines: [ClaudeStreamLine] = []
        var launcherNotices: [String] = []
        var malformed: [String] = []
        var empty = 0
    }

    static func url(_ name: String, subdirectory: String = "Fixtures") throws -> URL {
        let resource = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return try #require(Bundle.module.url(
            forResource: resource,
            withExtension: ext.isEmpty ? nil : ext,
            subdirectory: subdirectory
        ))
    }

    static func rawLines(_ name: String, subdirectory: String = "Fixtures") throws -> [Data] {
        let data = try Data(contentsOf: url(name, subdirectory: subdirectory))
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = []
        var current = Data()
        for byte in data {
            if byte == newline {
                lines.append(current)
                current = Data()
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Runs the full classify-then-decode pipeline over one fixture file.
    static func decode(_ name: String) throws -> DecodedFixture {
        var result = DecodedFixture()
        for line in try rawLines(name) {
            switch ClaudeLineClassifier.classify(line) {
            case .json(let value):
                result.lines.append(ClaudeStreamLine.decode(value))
            case .launcherNotice(let text):
                result.launcherNotices.append(text)
            case .malformedJSON(let text):
                result.malformed.append(text)
            case .tooLarge:
                Issue.record("unexpected oversized line in \(name)")
            case .empty:
                result.empty += 1
            }
        }
        return result
    }
}

extension FixtureSupport.DecodedFixture {
    var systemEvents: [ClaudeSystemEvent] {
        lines.compactMap { if case .system(let event) = $0 { return event } else { return nil } }
    }

    var streamEvents: [ClaudeStreamEventEnvelope] {
        lines.compactMap { if case .streamEvent(let env) = $0 { return env } else { return nil } }
    }

    var assistants: [ClaudeMessageEnvelope] {
        lines.compactMap { if case .assistant(let env) = $0 { return env } else { return nil } }
    }

    var users: [ClaudeMessageEnvelope] {
        lines.compactMap { if case .user(let env) = $0 { return env } else { return nil } }
    }

    var results: [ClaudeResult] {
        lines.compactMap { if case .result(let result) = $0 { return result } else { return nil } }
    }

    var inboundControlRequests: [ClaudeInboundControlRequest] {
        lines.compactMap { if case .controlRequest(let req) = $0 { return req } else { return nil } }
    }

    var controlResponses: [ClaudeControlResponseEnvelope] {
        lines.compactMap { if case .controlResponse(let env) = $0 { return env } else { return nil } }
    }

    var initializations: [ClaudeSystemInitialization] {
        systemEvents.compactMap { if case .initialize(let value) = $0 { return value } else { return nil } }
    }

    var unknownLines: [ClaudeStreamLine] {
        lines.filter { if case .unknown = $0 { return true } else { return false } }
    }
}
