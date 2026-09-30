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
/// **Who writes it.** The notification service extension records the pushing
/// Mac's count from every direct push (notify and dismiss) and delivers the
/// total as that push's badge; the app records the foreground Mac's live count
/// and drops a Mac the user forgets. Both processes share the app group's
/// defaults, one key per Mac, so writes for different Macs never race.
///
/// **One source file, two modules.** Besides this package, the file is
/// compiled straight into the notification service extension target, which
/// links no package graph (see `SupermuxSharedProjectIconStore` for why). Both
/// sides therefore run this exact code; keep it Foundation-only.
public struct SupermuxPhoneBadgeLedger {
    /// The app group the app and its notification service extension share
    /// (the same group as `SupermuxSharedProjectIconStore`).
    public static let appGroupIdentifier = "group.com.supermux.ios"

    /// Prefix of the one defaults key per Mac.
    static let keyPrefix = "supermux.phoneBadge."

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

    /// Records one Mac's own unread count and returns the badge: the total
    /// over every Mac. A blank Mac id records nothing and returns `count`.
    /// - Parameters:
    ///   - count: The Mac's own unread count (negative clamps to zero).
    ///   - macDeviceID: The Mac's device id, raw or as a pairing id.
    public func total(recording count: Int, forMacDeviceID macDeviceID: String) -> Int {
        let count = max(0, count)
        guard let key = Self.key(forMacDeviceID: macDeviceID) else { return count }
        if count == 0 {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(count, forKey: key)
        }
        return total()
    }

    /// Drops one Mac's count and returns the new total.
    /// - Parameter macDeviceID: The forgotten Mac's device id.
    public func total(forgetting macDeviceID: String) -> Int {
        if let key = Self.key(forMacDeviceID: macDeviceID) {
            defaults.removeObject(forKey: key)
        }
        return total()
    }

    /// The sum of every Mac's recorded count.
    public func total() -> Int {
        defaults.dictionaryRepresentation().reduce(0) { sum, entry in
            guard entry.key.hasPrefix(Self.keyPrefix), let count = entry.value as? Int else { return sum }
            return sum + max(0, count)
        }
    }

    /// One key per physical Mac, whichever spelling names it: the push's raw
    /// `macDeviceId` or the app's pairing key (its build tag after U+001F is
    /// dropped), with UUIDs lowercased like `cmxCanonicalDeviceID`. Two builds
    /// on one Mac therefore share a slot, the latest count winning — never
    /// counted twice.
    static func key(forMacDeviceID macDeviceID: String) -> String? {
        let device = macDeviceID
            .split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !device.isEmpty else { return nil }
        return keyPrefix + (UUID(uuidString: device)?.uuidString.lowercased() ?? device)
    }
}
