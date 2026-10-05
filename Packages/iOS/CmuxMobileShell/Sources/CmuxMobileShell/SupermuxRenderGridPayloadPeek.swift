// SUPERMUX:begin render-grid-sink-first
import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// The terminal a `terminal.render_grid` payload is for, read without
/// decoding the frame.
///
/// The Mac sends a render-grid frame for every terminal to every phone, and
/// the phone shows only the mounted ones. Decoding a frame (every row span
/// and style) before finding it is for a terminal nobody shows kept the main
/// actor busy while the focused terminal's frames waited in the same event
/// buffer. Reading only `surface_id` skips that work for unmounted terminals.
struct SupermuxRenderGridPayloadPeek: Decodable {
    /// Bare form, the live host's: the payload is the frame.
    let surfaceID: String?
    /// Wrapped form: the frame under `render_grid`.
    let wrapped: Wrapped?

    struct Wrapped: Decodable {
        let surfaceID: String?

        enum CodingKeys: String, CodingKey {
            case surfaceID = "surface_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id"
        case wrapped = "render_grid"
    }

    /// Reads the peek, or nil when the payload is not a JSON object.
    static func read(_ payload: Data) -> SupermuxRenderGridPayloadPeek? {
        try? JSONDecoder().decode(Self.self, from: payload)
    }

    /// The terminal the frame is for, whichever form carries it.
    var frameSurfaceID: String? {
        wrapped?.surfaceID ?? surfaceID
    }

    /// Decodes the frame once, in the form the peek found.
    func decodeFrame(_ payload: Data) -> MobileTerminalRenderGridFrame? {
        if wrapped != nil {
            return (try? MobileTerminalRenderGridEvent.decode(payload))?.frame
        }
        return try? MobileTerminalRenderGridFrame.decode(payload)
    }
}
// SUPERMUX:end render-grid-sink-first
