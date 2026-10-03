public import Foundation

/// One-time seeding of boolean preferences.
///
/// Used to turn features on by default for an app identity without taking a
/// user's choice away: a key that already holds a value (on OR off) is never
/// touched, and once `marker` is recorded the seed never runs again, so a
/// value the user later removes is not re-seeded either.
public enum SupermuxDefaultsSeed {
    /// Writes each key's value when the key is unset, once per `marker`.
    /// - Parameters:
    ///   - values: The keys to seed and the value each gets.
    ///   - marker: A defaults key recording that this seed ran.
    ///   - defaults: The defaults domain.
    /// - Returns: The keys it wrote, sorted.
    @discardableResult
    public static func applyOnce(
        _ values: [String: Bool],
        marker: String,
        defaults: UserDefaults
    ) -> [String] {
        guard !defaults.bool(forKey: marker) else { return [] }
        var seeded: [String] = []
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            seeded.append(key)
        }
        defaults.set(true, forKey: marker)
        return seeded.sorted()
    }
}
