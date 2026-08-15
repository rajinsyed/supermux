import Foundation

extension SupermuxHarnessRowBuilder {
    /// FNV-1a over the row's rendered inputs.
    ///
    /// Row equality on `(id, version)` is what keeps a streaming transcript
    /// from rebuilding every visible row per delta: the settled prefix hashes
    /// identically across commits, so only the tail re-renders.
    static func fingerprint(of row: SupermuxHarnessRow) -> UInt64 {
        var hash = FNV1a()
        switch row.kind {
        case .userPrompt(let text):
            hash.combine("u")
            hash.combine(text)
        case .assistantProse(let text, let isStreaming):
            hash.combine("p")
            hash.combine(text)
            hash.combine(isStreaming)
        case .thinking(let text, let isStreaming):
            hash.combine("t")
            hash.combine(text)
            hash.combine(isStreaming)
        case .toolGroup(let group):
            hash.combine("g")
            hash.combine(group.autoOpen)
            for tool in group.tools {
                hash.combine(tool.id)
                hash.combine(tool.name)
                hash.combine(UInt64(tool.status.fingerprintTag))
                // Hash the RAW inputs, not the derived chip bodies. `verb`,
                // `chipSubject`, `invocationBlock` and `detail` are all pure
                // over these three, so this covers them exactly — and it avoids
                // re-encoding JSON and re-parsing a 600-line diff on every
                // streaming delta, which is what a fingerprint exists to
                // prevent.
                hash.combine(tool.input)
                hash.combine(tool.resultText ?? "")
                if let toolUseResult = tool.toolUseResult { hash.combine(toolUseResult) }
                for stat in tool.diffStats {
                    hash.combine(stat.path)
                    hash.combine(stat.additions)
                    hash.combine(stat.deletions)
                }
            }
        case .result(let summary):
            hash.combine("r")
            hash.combine(summary.durationMs ?? 0)
            hash.combine(summary.numTurns ?? 0)
            hash.combine(summary.isError)
        case .notice(let notice):
            hash.combine("n")
            hash.combine(notice.title)
            hash.combine(notice.detail ?? "")
        }
        // The stamp is a rendered input of its own: a settled tool group looks
        // byte-identical to its streaming self apart from this.
        hash.combine(row.timestamp != nil)
        hash.combine(row.turnStart)
        return hash.value
    }
}

/// The 64-bit FNV-1a used for row fingerprints.
struct FNV1a {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
    }

    mutating func combine(_ text: String) {
        combine(text.utf8)
        // A length-tagged separator, so ("ab","c") and ("a","bc") differ.
        combine(UInt64(text.utf8.count))
    }

    mutating func combine(_ number: UInt64) {
        withUnsafeBytes(of: number.littleEndian) { combine($0) }
    }

    /// A signed count off the wire.
    ///
    /// Bit-pattern, never `UInt64(_:)`: the CLI's numbers are untrusted, and
    /// `UInt64(-1)` TRAPS ("Negative value is not representable"), taking the
    /// app down from a projection that is supposed to be total. For every
    /// non-negative value this hashes identically to the unsigned overload.
    mutating func combine(_ number: Int) {
        combine(UInt64(bitPattern: Int64(number)))
    }

    mutating func combine(_ flag: Bool) {
        combine([flag ? UInt8(1) : UInt8(0)])
    }

    /// A JSON payload, walked structurally.
    ///
    /// Deliberately not `value.hashValue`: Swift seeds `Hashable` per process,
    /// so a row version built from it would differ between two runs and could
    /// not be persisted or sent over the wire. Object keys are sorted so the
    /// same payload always hashes the same.
    mutating func combine(_ value: ClaudeJSONValue) {
        switch value {
        case .null:
            combine(UInt64(0))
        case .bool(let flag):
            combine(UInt64(1))
            combine(flag)
        case .integer(let number):
            combine(UInt64(2))
            combine(UInt64(bitPattern: number))
        case .number(let number):
            combine(UInt64(3))
            combine(number.bitPattern)
        case .string(let text):
            combine(UInt64(4))
            combine(text)
        case .array(let elements):
            combine(UInt64(5))
            combine(UInt64(elements.count))
            for element in elements { combine(element) }
        case .object(let object):
            combine(UInt64(6))
            combine(UInt64(object.count))
            for key in object.keys.sorted() {
                combine(key)
                if let child = object[key] { combine(child) }
            }
        }
    }
}

private extension SupermuxHarnessToolCall.Status {
    var fingerprintTag: UInt8 {
        switch self {
        case .running: return 0
        case .succeeded: return 1
        case .failed: return 2
        }
    }
}
