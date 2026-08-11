import Intents
import UIKit
import UserNotifications

/// Rewrites an incoming Supermux push into a **communication notification** so
/// iOS presents it the way a message from a person is presented: a large
/// circular avatar on the left, the small app icon badged onto its corner, and
/// the sender's name in bold.
///
/// **Why an extension is required at all.** `UNNotificationContent.updating(from:)`
/// is the only API that applies that treatment, and for a *remote* push it must
/// be called inside `UNNotificationServiceExtension.didReceive` — the app
/// process is not running when a banner arrives on a locked phone. There is no
/// APNs payload key that does this.
///
/// **The avatar is drawn here, not downloaded.** A project's icon lives on the
/// paired Mac and reaches the phone only over the app's encrypted RPC session,
/// which this out-of-process, short-lived extension cannot open. So the payload
/// carries the project's *identity* (name + accent), and this extension renders
/// the same gradient-and-initial chip the Mac sidebar and the in-app feed draw.
/// No app group, no network, no shared container.
///
/// **Failure is always graceful.** Every path — missing metadata, a render
/// failure, a throwing `updating(from:)`, or the extension's execution budget
/// expiring — delivers the original notification unchanged. A push must never
/// be lost to a decoration problem.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content

        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let project = PushProject(userInfo: request.content.userInfo) else {
            deliver(request.content)
            return
        }
        bestAttemptContent = content

        // The alert title is the agent ("Claude Code"), which is what should
        // read as the sender. Without one there is nothing to bold, so the
        // communication treatment would look broken rather than better.
        let senderName = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !senderName.isEmpty else {
            deliver(content)
            return
        }

        let avatar = ProjectAvatarRenderer.pngData(
            projectID: project.id,
            name: project.name,
            colorHex: project.colorHex,
            symbolName: project.iconSymbol
        ).map(INImage.init(imageData:))

        // Keyed on the project, so every notification from one repo lands in a
        // single conversation. The sender handle keeps the agent distinct
        // within it, matching how the same project can run several agents.
        let senderIdentifier = "\(project.id):\(senderName)"
        let sender = INPerson(
            personHandle: INPersonHandle(value: senderIdentifier, type: .unknown),
            nameComponents: nil,
            displayName: senderName,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: senderIdentifier
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: INSpeakableString(spokenPhrase: project.name),
            conversationIdentifier: project.id,
            serviceName: "Supermux",
            sender: sender,
            attachments: nil
        )
        // The group image is what iOS actually paints for a group-style
        // conversation; the sender carries the same bytes as a fallback.
        if let avatar {
            intent.setImage(avatar, forParameterNamed: \INSendMessageIntent.speakableGroupName)
        }

        // Donation is part of the contract: an intent that was never donated is
        // a common cause of the avatar silently not appearing.
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        do {
            let updated = try content.updating(from: intent)
            // The app routes taps, replies, and dismiss-sync entirely off
            // `userInfo["cmux"]`. If a future OS release ever rewrote or
            // dropped it, a prettier banner that cannot open the right terminal
            // would be a strictly worse notification — so fall back instead.
            guard Self.cmuxPayload(in: updated.userInfo) == Self.cmuxPayload(in: content.userInfo) else {
                deliver(content)
                return
            }
            bestAttemptContent = updated
            deliver(updated)
        } catch {
            deliver(content)
        }
    }

    /// iOS is about to reclaim the extension: ship the best content we have.
    override func serviceExtensionTimeWillExpire() {
        guard let bestAttemptContent else { return }
        deliver(bestAttemptContent)
    }

    /// Calls the content handler exactly once. A second call would trap.
    private func deliver(_ content: UNNotificationContent) {
        guard let contentHandler else { return }
        self.contentHandler = nil
        contentHandler(content)
    }

    private static func cmuxPayload(in userInfo: [AnyHashable: Any]) -> NSDictionary? {
        userInfo["cmux"] as? NSDictionary
    }
}

/// The project identity carried in the push, mirroring the `cmux.project`
/// object `SupermuxPhonePushService` emits.
///
/// Re-declared here rather than imported: an app extension links its own copy
/// of every dependency, and pulling the mobile package graph into a process
/// with a hard execution budget would cost launch time for one small struct.
private struct PushProject {
    let id: String
    let name: String
    let colorHex: String?
    let iconSymbol: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let cmux = userInfo["cmux"] as? [String: Any],
              let project = cmux["project"] as? [String: Any],
              let rawID = project["id"] as? String,
              let rawName = project["name"] as? String else { return nil }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty else { return nil }
        self.id = id
        self.name = name
        self.colorHex = project["colorHex"] as? String
        self.iconSymbol = project["iconSymbol"] as? String
    }
}

/// Draws the project avatar: the accent gradient carrying the project's SF
/// Symbol, or its initial.
///
/// Deliberately mirrors `SupermuxProjectAccentPalette` (macOS/iOS app) rather
/// than importing it — same 11-color palette, same splitmix64-finalized hash —
/// so a project's avatar is the same color on the lock screen as in the
/// sidebar. If either side's palette changes, both must change.
private enum ProjectAvatarRenderer {
    /// Accent palette: Tailwind's `-500` series minus slate, which reads as
    /// "no color". Must stay identical to `SupermuxProjectAccentPalette.derivedHexes`.
    private static let derivedHexes = [
        "#ef4444", "#f97316", "#eab308", "#84cc16", "#22c55e", "#14b8a6",
        "#06b6d4", "#3b82f6", "#6366f1", "#a855f7", "#ec4899",
    ]

    /// - Parameters:
    ///   - projectID: The project's STABLE id — the derivation key. Keying on
    ///     the name instead would recolor a project the moment it is renamed.
    ///   - name: Display name, used only for the letter fallback.
    static func pngData(
        projectID: String,
        name: String,
        colorHex: String?,
        symbolName: String?
    ) -> Data? {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let base = color(colorHex: colorHex, projectID: projectID)

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            context.cgContext.saveGState()
            context.cgContext.addEllipse(in: bounds)
            context.cgContext.clip()

            // The same topLeading -> bottomTrailing two-stop wash the app uses.
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [base.cgColor, base.withAlphaComponent(0.72).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            } else {
                base.setFill()
                context.cgContext.fill(bounds)
            }
            context.cgContext.restoreGState()

            drawGlyph(name: name, symbolName: symbolName, in: bounds)
        }
        return image.pngData()
    }

    /// The SF Symbol when it resolves, otherwise the name's initial. A stale
    /// symbol name degrades to the letter, never to an empty circle.
    private static func drawGlyph(name: String, symbolName: String?, in bounds: CGRect) {
        let glyphSide = bounds.width * 0.44
        if let symbolName, !symbolName.isEmpty,
           let symbol = UIImage(
               systemName: symbolName,
               withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphSide, weight: .semibold)
           )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            symbol.draw(in: CGRect(
                x: bounds.midX - symbol.size.width / 2,
                y: bounds.midY - symbol.size.height / 2,
                width: symbol.size.width,
                height: symbol.size.height
            ))
            return
        }

        let attributed = NSAttributedString(
            string: initial(for: name),
            attributes: [
                .font: UIFont.systemFont(ofSize: glyphSide * 1.1, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
        )
        let textSize = attributed.size()
        attributed.draw(at: CGPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2
        ))
    }

    private static func initial(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "?"
        }
        return String(first).uppercased()
    }

    /// The project's explicit accent, or one derived from its id.
    private static func color(colorHex: String?, projectID: String) -> UIColor {
        if let colorHex, let parsed = parse(hex: colorHex) { return parsed }
        let index = slot(for: projectID, slotCount: derivedHexes.count)
        return parse(hex: derivedHexes[index]) ?? .systemIndigo
    }

    private static func parse(hex: String) -> UIColor? {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// djb2 plus a splitmix64 finalizer. The finalizer is load-bearing: djb2's
    /// multiplier is 33 == 3 * 11, so at an 11-slot palette the multiply
    /// vanishes under the modulus and nearly every id collapses onto one color.
    /// Must match `SupermuxProjectAccentPalette.slot(for:slotCount:)` exactly.
    private static func slot(for projectID: String, slotCount: Int) -> Int {
        var hash: UInt64 = 5381
        for scalar in projectID.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        hash ^= hash >> 30
        hash = hash &* 0xbf58_476d_1ce4_e5b9
        hash ^= hash >> 27
        hash = hash &* 0x94d0_49bb_1331_11eb
        hash ^= hash >> 31
        return Int(hash % UInt64(max(1, slotCount)))
    }
}
