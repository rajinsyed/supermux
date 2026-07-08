import Foundation
import Testing

/// POL-04 for this package: every `supermux.*` key in the package-owned
/// string catalog carries a non-empty translation for BOTH `en` and `ja`,
/// every key the sources reference exists in the catalog, and no bare string
/// literal reaches `Text()`/`Label()`/`Button()` outside `String(localized:)`.
@Suite struct LocalizableCatalogTests {
    private static let requiredLocales = ["en", "ja"]

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupermuxMobileUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
    }

    private var sourcesRoot: URL {
        packageRoot.appendingPathComponent("Sources/SupermuxMobileUI")
    }

    private var catalogURL: URL {
        sourcesRoot.appendingPathComponent("Resources/Localizable.xcstrings")
    }

    private func loadCatalog() throws -> (sourceLanguage: String, strings: [String: [String: Any]]) {
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sourceLanguage = try #require(root["sourceLanguage"] as? String)
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        return (sourceLanguage, strings)
    }

    private func swiftSources() throws -> [(name: String, contents: String)] {
        let files = try #require(FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        ))
        return try files.compactMap { element in
            guard let url = element as? URL, url.pathExtension == "swift" else { return nil }
            return (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
        }
    }

    @Test func everyKeyIsSupermuxNamespacedAndTranslatedInEnglishAndJapanese() throws {
        let catalog = try loadCatalog()
        #expect(catalog.sourceLanguage == "en")
        #expect(!catalog.strings.isEmpty)

        for (key, entry) in catalog.strings {
            #expect(key.hasPrefix("supermux."), "non-supermux key in the fork catalog: \(key)")
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for locale in Self.requiredLocales {
                let unit = (localizations[locale]?["stringUnit"]) as? [String: Any]
                let value = unit?["value"] as? String
                #expect(
                    value?.isEmpty == false,
                    "key \(key) is missing a non-empty \(locale) translation"
                )
                #expect(
                    unit?["state"] as? String == "translated",
                    "key \(key) \(locale) is not marked translated"
                )
            }
        }
    }

    @Test func everyKeyTheSourcesReferenceExistsInTheCatalog() throws {
        let catalog = try loadCatalog()
        let keyPattern = try NSRegularExpression(pattern: #"String\(\s*localized:\s*"([^"]+)""#)
        var referenced: Set<String> = []
        for source in try swiftSources() {
            let range = NSRange(source.contents.startIndex..., in: source.contents)
            for match in keyPattern.matches(in: source.contents, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source.contents) else { continue }
                referenced.insert(String(source.contents[keyRange]))
            }
        }
        #expect(!referenced.isEmpty, "expected the sources to reference localized keys")
        for key in referenced.sorted() {
            #expect(catalog.strings[key] != nil, "source references key missing from catalog: \(key)")
        }
    }

    @Test func noBareStringLiteralsReachTextLabelOrButton() throws {
        // `Text("…")`, `Label("…"`, `Button("…"` with a literal first argument
        // bypass the catalog. Data-driven text (`Text(row.name)`) and
        // `String(localized:)` arguments do not match this pattern.
        let barePattern = try NSRegularExpression(pattern: #"(Text|Label|Button)\(\s*""#)
        for source in try swiftSources() {
            let range = NSRange(source.contents.startIndex..., in: source.contents)
            let matches = barePattern.matches(in: source.contents, range: range)
            #expect(
                matches.isEmpty,
                "\(source.name) passes a bare string literal to Text/Label/Button"
            )
        }
    }
}
