import CmuxMobileSimulatorStream
import CoreGraphics
import Foundation

/// How sharp a remote-simulator viewer asks the owning Mac to encode.
///
/// The cap bounds the encoded long side; bitrate adapts to the link on the
/// owning Mac by itself. Auto follows the viewer's own backing pixels, the
/// others are the iPhone app's presets (`SimStreamQualityPreset`). One choice
/// per viewing Mac, shared by every viewer tab.
enum SupermuxRemoteSimulatorQuality: String, CaseIterable, Sendable {
    case auto
    case high
    case balanced
    case dataSaver

    static let defaultsKey = "supermux.remoteSimulator.quality"

    /// This Mac's last choice.
    static var saved: SupermuxRemoteSimulatorQuality {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The fixed long-side cap, or nil for Auto.
    var fixedLongSidePixels: UInt16? {
        switch self {
        case .auto: nil
        case .high: SimStreamQualityPreset.high.maximumLongSidePixels
        case .balanced: SimStreamQualityPreset.balanced.maximumLongSidePixels
        case .dataSaver: SimStreamQualityPreset.dataSaver.maximumLongSidePixels
        }
    }

    /// Auto's cap for a viewer `backingPixels` long: rounded up to 160 px
    /// steps (so a resize does not rebuild the encoder for every pixel),
    /// between Data Saver and High.
    static func autoLongSide(forBackingPixels backingPixels: CGFloat) -> UInt16 {
        let rounded = (backingPixels / 160).rounded(.up) * 160
        let floor = CGFloat(SimStreamQualityPreset.dataSaver.maximumLongSidePixels)
        let ceiling = CGFloat(SimStreamQualityPreset.high.maximumLongSidePixels)
        return UInt16(min(max(rounded, floor), ceiling))
    }

    var title: String {
        switch self {
        case .auto: String(localized: "supermux.remoteSimulator.quality.auto", defaultValue: "Auto")
        case .high: String(localized: "supermux.remoteSimulator.quality.high", defaultValue: "High")
        case .balanced: String(localized: "supermux.remoteSimulator.quality.balanced", defaultValue: "Balanced")
        case .dataSaver: String(localized: "supermux.remoteSimulator.quality.dataSaver", defaultValue: "Data Saver")
        }
    }
}
