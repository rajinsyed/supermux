import Foundation

/// The phone's app-icon badge as the total of every Mac's own unread count.
///
/// **Why it exists.** Each Mac reports only its OWN unread notifications — a
/// notification mirrored from another Mac is that Mac's to badge — in its
/// direct pushes (`aps.badge`) and over the live session
/// (`notification.reconcile`, `notification.badge`). Applied as-is, the badge
/// shows whichever Mac spoke last. So the phone keeps the latest count per Mac
/// and badges the sum.
///
/// **One slot per build.** Like everything else the phone tracks per Mac
/// (`MacPairingKey`), a slot is one app instance: Stable and Nightly on one
/// Mac are two slots, so one build's dismiss push never erases the other's
/// count. Only the builds a Release phone can pair with get a slot (tags
/// `default`, `nightly`, `rc`, as `MobileMacBuildCompatibilityPolicy.official`
/// admits; no tag is `default`). A tagged dev or dogfood build that shares the
/// Mac's push setup gets none: its pushes neither change the badge nor leave
/// a slot behind that would outlive the build.
///
/// **Who writes it.** The notification service extension records the pushing
/// build's count from every direct push (notify and dismiss) and delivers the
/// total as that push's badge; the app records the foreground build's live
/// count and drops a build the user forgets. Both processes share the app
/// group's defaults, one key per build, so writes for different builds never
/// race.
///
/// **One source file, two modules.** Besides this package, the file is
/// compiled straight into the notification service extension target, which
/// links no package graph (see `SupermuxSharedProjectIconStore` for why). Both
/// sides therefore run this exact code; keep it Foundation-only.
public struct SupermuxPhoneBadgeLedger {
    /// The app group the app and its notification service extension share
    /// (the same group as `SupermuxSharedProjectIconStore`).
    public static let appGroupIdentifier = "group.com.supermux.ios"

    /// Prefix of the one defaults key per build: `<prefix><device>@<tag>`.
    /// Keys without `@` are the pre-tag per-Mac slots, migrated on first use.
    static let keyPrefix = "supermux.phoneBadge."

    /// The build tags a Release phone pairs with; `nil`/blank means `default`.
    static let pairableTags: Set<String> = ["default", "nightly", "rc"]

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The ledger in the shared app group, or `nil` without one: a build
    /// signed without the group (the personal-team dogfood extension) or any
    /// platform but iOS, where host-side tests must never write the real
    /// group. Callers then apply the Mac's own count, as before the ledger.
    /// - Parameter fileManager: Injected for tests.
    public static func shared(fileManager: FileManager = .default) -> SupermuxPhoneBadgeLedger? {
        #if os(iOS)
        guard fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil,
              let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
        return SupermuxPhoneBadgeLedger(defaults: defaults)
        #else
        return nil
        #endif
    }

    /// Records one build's own unread count and returns the badge: the total
    /// over every build. A blank Mac id records nothing and returns `count`; a
    /// build the phone cannot pair with records nothing and returns the total.
    /// - Parameters:
    ///   - count: The build's own unread count (negative clamps to zero).
    ///   - macDeviceID: The Mac's device id, raw or as a pairing id (a tag
    ///     after U+001F is used when `instanceTag` is `nil`).
    ///   - instanceTag: The build's instance tag (`macInstanceTag`).
    public func total(recording count: Int, forMacDeviceID macDeviceID: String, instanceTag: String? = nil) -> Int {
        let count = max(0, count)
        guard let slot = Self.slot(forMacDeviceID: macDeviceID, instanceTag: instanceTag) else { return count }
        migrateUntaggedSlots()
        if let key = slot.key {
            if count == 0 {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(count, forKey: key)
            }
        }
        return total()
    }

    /// Drops one build's count and returns the new total.
    /// - Parameters:
    ///   - macDeviceID: The forgotten Mac's device id (or pairing id).
    ///   - instanceTag: The forgotten build's tag (`nil` is `default`).
    public func total(forgetting macDeviceID: String, instanceTag: String? = nil) -> Int {
        migrateUntaggedSlots()
        if let key = Self.slot(forMacDeviceID: macDeviceID, instanceTag: instanceTag)?.key {
            defaults.removeObject(forKey: key)
        }
        return total()
    }

    /// The sum of every build's recorded count.
    public func total() -> Int {
        defaults.dictionaryRepresentation().reduce(0) { sum, entry in
            guard entry.key.hasPrefix(Self.keyPrefix), let count = entry.value as? Int else { return sum }
            return sum + max(0, count)
        }
    }

    /// Where one build's count lives: `key` is `nil` for a build the phone
    /// cannot pair with (it has no slot). `nil` itself for a blank device id.
    struct Slot: Equatable {
        let key: String?
    }

    /// The slot for a device id (raw push field or pairing id, UUIDs
    /// lowercased like `cmxCanonicalDeviceID`) and a tag (normalized; blank or
    /// missing is `default`).
    static func slot(forMacDeviceID macDeviceID: String, instanceTag: String?) -> Slot? {
        let parts = macDeviceID.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        let device = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !device.isEmpty else { return nil }
        let rawTag = instanceTag ?? parts.dropFirst().first.map(String.init)
        let tag = normalizedTag(rawTag)
        guard pairableTags.contains(tag) else { return Slot(key: nil) }
        return Slot(key: keyPrefix + canonicalDevice(device) + "@" + tag)
    }

    private static func normalizedTag(_ tag: String?) -> String {
        let trimmed = (tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "default" : trimmed
    }

    private static func canonicalDevice(_ device: String) -> String {
        UUID(uuidString: device)?.uuidString.lowercased() ?? device
    }

    /// Moves each pre-tag per-Mac slot into that Mac's `default` build (the
    /// build it almost always was), unless that build already reported a
    /// fresher count; never leaves both to be summed.
    private func migrateUntaggedSlots() {
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(Self.keyPrefix) && !key.dropFirst(Self.keyPrefix.count).contains("@") {
            defaults.removeObject(forKey: key)
            let tagged = key + "@default"
            if let count = value as? Int, count > 0, defaults.object(forKey: tagged) == nil {
                defaults.set(count, forKey: tagged)
            }
        }
    }
}
