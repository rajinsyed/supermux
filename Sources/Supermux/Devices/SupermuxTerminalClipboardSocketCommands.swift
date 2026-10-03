#if DEBUG
import AppKit
import Foundation

/// DEBUG-only `supermux.devices.terminal_clipboard.*` drivers for
/// `tests/supermux/loopback_terminal_clipboard_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``:
///
/// - `terminal_clipboard.writes {surface_id, clear?}`: every clipboard write
///   that terminal's Ghostty asked for since the last clear, in order, each
///   `{location: standard|selection, accepted}` (``SupermuxTerminalClipboardWrites``).
///   With the loopback device the other Mac's terminal is in this app too, so
///   only this record tells the mirror's write from the source's.
/// - `terminal_clipboard.pasteboard {action, text?, path?}` on the general
///   pasteboard: `snapshot` (keeps every item and type in memory),
///   `restore` (puts that snapshot back), `write_text {text}`,
///   `write_png {path}` (the file's bytes as `public.png`, as a screenshot
///   copy leaves them) and `read_text`. The suite snapshots the user's
///   clipboard first and restores it last.
/// - `terminal_clipboard.old_host {enabled}`: this host stops advertising
///   `supermux.terminal_attachments.v1`, as a Supermux from before uploads.
@MainActor
enum SupermuxTerminalClipboardSocketCommands {
    static let methodPrefix = "terminal_clipboard."

    /// Read by the nonisolated capability list (`SupermuxMobileCapabilities`).
    nonisolated(unsafe) static var pretendsOldHost = false

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func handles<S: StringProtocol>(_ name: S) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle<S: StringProtocol>(_ name: S, _ params: [String: Any]) throws -> [String: Any] {
        switch String(name.dropFirst(methodPrefix.count)) {
        case "writes": return try writes(params)
        case "pasteboard": return try pasteboard(params)
        case "old_host":
            guard let enabled = params["enabled"] as? Bool else { throw HookError(message: "enabled is required") }
            pretendsOldHost = enabled
            return ["enabled": enabled]
        default: throw HookError(message: "unknown terminal_clipboard method \(name)")
        }
    }

    // MARK: - Clipboard writes

    private struct Write {
        let surfaceID: UUID
        let location: String
        let accepted: Bool
    }

    nonisolated private static let writeLock = NSLock()
    nonisolated(unsafe) private static var recordedWrites: [Write] = []

    /// Records one write decision (any thread).
    nonisolated static func recordWrite(surfaceID: UUID, location: String, accepted: Bool) {
        writeLock.withLock {
            recordedWrites.append(Write(surfaceID: surfaceID, location: location, accepted: accepted))
            if recordedWrites.count > 500 { recordedWrites.removeFirst(recordedWrites.count - 500) }
        }
    }

    private static func writes(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["surface_id"] as? String, let surfaceID = UUID(uuidString: raw) else {
            throw HookError(message: "surface_id is required")
        }
        let clear = params["clear"] as? Bool ?? false
        let rows = writeLock.withLock { () -> [[String: Any]] in
            let mine = recordedWrites.filter { $0.surfaceID == surfaceID }
            if clear { recordedWrites.removeAll { $0.surfaceID == surfaceID } }
            return mine.map { ["location": $0.location, "accepted": $0.accepted] }
        }
        return ["surface_id": surfaceID.uuidString, "writes": rows]
    }

    // MARK: - General pasteboard

    private static var snapshot: [[NSPasteboard.PasteboardType: Data]]?

    private static func pasteboard(_ params: [String: Any]) throws -> [String: Any] {
        let board = NSPasteboard.general
        switch params["action"] as? String {
        case "snapshot":
            snapshot = (board.pasteboardItems ?? []).map { item in
                var types: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types { types[type] = item.data(forType: type) }
                return types
            }
            return ["items": snapshot?.count ?? 0]
        case "restore":
            guard let snapshot else { return ["restored": false] }
            board.clearContents()
            let items = snapshot.map { types -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
            Self.snapshot = nil
            return ["restored": true, "items": items.count]
        case "write_text":
            guard let text = params["text"] as? String else { throw HookError(message: "text is required") }
            board.clearContents()
            board.setString(text, forType: .string)
            return ["change_count": board.changeCount]
        case "write_png":
            guard let path = params["path"] as? String,
                  let data = FileManager.default.contents(atPath: path) else {
                throw HookError(message: "path must name a readable file")
            }
            board.clearContents()
            board.setData(data, forType: .png)
            return ["change_count": board.changeCount, "bytes": data.count]
        case "read_text":
            return ["text": board.string(forType: .string) ?? NSNull(), "change_count": board.changeCount]
        default:
            throw HookError(message: "action must be snapshot, restore, write_text, write_png or read_text")
        }
    }
}
#endif
