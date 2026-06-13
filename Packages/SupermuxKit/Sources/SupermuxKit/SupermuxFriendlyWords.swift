import Foundation

/// A small, family-friendly word bag for generating readable branch names like
/// `cheerful-umbrella`.
///
/// Mirrors piggycode's use of the `friendly-words` package (a predicate +
/// object pair). The lists are intentionally curated and modest in size:
/// ``SupermuxBranchName`` deduplicates collisions with a numeric suffix, so a
/// few thousand combinations is plenty for unique, human-pronounceable names.
enum SupermuxFriendlyWords {
    /// Adjective-like words used as the first half of a generated name.
    static let predicates: [String] = [
        "adorable", "agile", "amber", "ancient", "bold", "brave", "breezy",
        "bright", "calm", "cheerful", "clever", "cosmic", "cozy", "crimson",
        "crisp", "curious", "daring", "dapper", "dazzling", "eager", "electric",
        "elegant", "fancy", "fearless", "festive", "fluffy", "fuzzy", "gentle",
        "gilded", "gleaming", "golden", "graceful", "happy", "hidden", "humble",
        "jolly", "keen", "lively", "lucky", "lunar", "mellow", "merry", "mighty",
        "nimble", "noble", "polished", "quiet", "quirky", "radiant", "rapid",
        "rustic", "scarlet", "serene", "shiny", "silent", "silver", "sleek",
        "snappy", "spry", "sunny", "swift", "tidy", "vivid", "witty", "zesty",
    ]

    /// Noun-like words used as the second half of a generated name.
    static let objects: [String] = [
        "acorn", "anchor", "aspen", "badger", "beacon", "blossom", "breeze",
        "brook", "canyon", "cedar", "cipher", "comet", "compass", "coral",
        "cove", "dawn", "delta", "dune", "ember", "falcon", "fern", "forest",
        "fox", "galaxy", "garden", "harbor", "hawk", "heron", "island", "ivory",
        "lagoon", "lantern", "ledger", "lily", "lynx", "maple", "meadow", "mesa",
        "meteor", "nebula", "oasis", "orchard", "otter", "pebble", "pine",
        "prairie", "quartz", "raven", "reef", "ridge", "river", "robin", "summit",
        "thicket", "tundra", "umbrella", "valley", "willow", "wombat", "zephyr",
    ]
}
