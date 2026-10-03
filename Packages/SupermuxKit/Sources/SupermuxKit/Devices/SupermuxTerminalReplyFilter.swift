public import Foundation

/// Removes terminal query replies from a device mirror's outgoing input.
///
/// A device mirror's local Ghostty parses the other Mac's terminal output, so
/// it answers the queries in that output (device attributes, cursor position,
/// colors, versions) as if it were the terminal. The other Mac's own terminal
/// already answered them, so a second answer would reach the program as
/// typed input. This drops complete replies and passes every other byte
/// through unchanged: keystrokes, mouse reports, focus events, paste markers
/// and any incomplete sequence at the end of a chunk. Ghostty writes each
/// reply in one piece, so a chunk never splits one.
public enum SupermuxTerminalReplyFilter {
    private static let escape: UInt8 = 0x1B

    public static func removingReplies(from data: Data) -> Data {
        guard data.contains(escape) else { return data }
        let bytes = [UInt8](data)
        var output = Data()
        output.reserveCapacity(bytes.count)
        var keptFrom = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == escape, let length = replyLength(bytes, at: index) {
                output.append(contentsOf: bytes[keptFrom..<index])
                index += length
                keptFrom = index
                continue
            }
            index += 1
        }
        output.append(contentsOf: bytes[keptFrom..<bytes.count])
        return output
    }

    /// The length of the complete reply starting at the ESC at `start`, or
    /// nil when the bytes there are not one.
    private static func replyLength(_ bytes: [UInt8], at start: Int) -> Int? {
        guard start + 1 < bytes.count else { return nil }
        switch bytes[start + 1] {
        case 0x5B: // CSI
            return csiReplyLength(bytes, at: start)
        case 0x5D: // OSC, ends in BEL or ST
            return stringLength(bytes, at: start, endsWithBEL: true)
        case 0x50, 0x5F, 0x5E, 0x58: // DCS, APC, PM, SOS, end in ST
            return stringLength(bytes, at: start, endsWithBEL: false)
        default:
            return nil
        }
    }

    private static func csiReplyLength(_ bytes: [UInt8], at start: Int) -> Int? {
        var cursor = start + 2
        var parameters: [UInt8] = []
        var intermediates: [UInt8] = []
        while cursor < bytes.count {
            let byte = bytes[cursor]
            switch byte {
            case 0x30...0x3F where intermediates.isEmpty:
                parameters.append(byte)
            case 0x20...0x2F:
                intermediates.append(byte)
            case 0x40...0x7E:
                return isReply(final: byte, parameters: parameters, intermediates: intermediates)
                    ? cursor - start + 1 : nil
            default:
                return nil
            }
            cursor += 1
        }
        return nil
    }

    /// The CSI replies a terminal sends. No key encoding ends in these finals
    /// with these shapes: kitty keys are `CSI code;mods u` without `?`, and a
    /// device mirror forwards function keys as key events, not bytes.
    private static func isReply(final: UInt8, parameters: [UInt8], intermediates: [UInt8]) -> Bool {
        let privateMarker = parameters.first.map { $0 == 0x3F || $0 == 0x3E } ?? false
        switch (final, intermediates) {
        case (0x63, []): // c: DA1 `?`, DA2 `>`
            return privateMarker
        case (0x52, []): // R: CPR `row;col`, DECXCPR `?row;col;page`
            return parameters.first == 0x3F || isNumericFields(parameters, count: 2)
        case (0x6E, []): // n: DSR `0`/`3`, private `?…`
            return parameters.first == 0x3F || parameters == [0x30] || parameters == [0x33]
        case (0x75, []): // u: kitty flags reply `?flags`
            return parameters.first == 0x3F
        case (0x79, [0x24]): // $y: DECRPM
            return true
        case (0x74, []): // t: XTWINOPS reports
            return !parameters.isEmpty
        default:
            return false
        }
    }

    private static func isNumericFields(_ parameters: [UInt8], count: Int) -> Bool {
        let fields = parameters.split(separator: 0x3B, omittingEmptySubsequences: false)
        return fields.count == count && fields.allSatisfy { field in
            !field.isEmpty && field.allSatisfy { (0x30...0x39).contains($0) }
        }
    }

    /// The length of a complete string control sequence (terminated by ST,
    /// or by BEL for OSC), or nil when it is unterminated.
    private static func stringLength(_ bytes: [UInt8], at start: Int, endsWithBEL: Bool) -> Int? {
        var cursor = start + 2
        while cursor < bytes.count {
            if endsWithBEL, bytes[cursor] == 0x07 { return cursor - start + 1 }
            if bytes[cursor] == escape, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x5C {
                return cursor - start + 2
            }
            cursor += 1
        }
        return nil
    }
}
