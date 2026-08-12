public import Foundation
public import SwiftUI
import CmuxFoundation

/// One renderable run of assistant prose: markdown text or a fenced code block.
///
/// Adapted from `CmuxAgentChatUI`'s `ChatProseSegment` / `ChatProseSegmenter` /
/// `ChatTextBlock` (~200 LOC, copied rather than imported: that package is 706
/// iOS-shaped files and pulls Highlightr as a hard dependency, and the harness
/// needs three pure types out of it).
public struct SupermuxProseSegment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case text
        case code(language: String?)
    }

    public let index: Int
    public let kind: Kind
    public let content: String
    public var id: Int { index }
}

/// Splits prose into text runs and fenced code blocks.
///
/// An unterminated fence swallows the tail as code, which is exactly right
/// while a fence is still streaming in.
public struct SupermuxProseSegmenter: Sendable {
    public init() {}

    public func segments(from text: String) -> [SupermuxProseSegment] {
        var segments: [SupermuxProseSegment] = []
        var currentText: [Substring] = []
        var codeLanguage: String?
        var codeLines: [Substring] = []
        var inCode = false

        func flushText() {
            let joined = currentText.joined(separator: "\n")
            currentText = []
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            segments.append(
                SupermuxProseSegment(index: segments.count, kind: .text, content: trimmed)
            )
        }

        func flushCode() {
            let joined = codeLines.joined(separator: "\n")
            codeLines = []
            segments.append(
                SupermuxProseSegment(
                    index: segments.count,
                    kind: .code(language: codeLanguage),
                    content: joined
                )
            )
            codeLanguage = nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") {
                if inCode {
                    inCode = false
                    flushCode()
                } else {
                    inCode = true
                    flushText()
                    let language = stripped.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }
            if inCode {
                codeLines.append(line)
            } else {
                currentText.append(line)
            }
        }
        if inCode { flushCode() } else { flushText() }
        return segments
    }
}

/// One block-level element of prose. Coding agents emit headings and lists in
/// nearly every reply; without block layout the markers render literally.
public struct SupermuxTextBlock: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case heading(level: Int)
        case paragraph
        case bullet(indent: Int)
        case ordered(marker: String, indent: Int)
        case quote
        case rule
    }

    public let index: Int
    public let kind: Kind
    public let text: String
    public var id: Int { index }
}

/// Parses a prose text run into block-level elements.
public struct SupermuxTextBlockParser: Sendable {
    public init() {}

    public func blocks(from text: String) -> [SupermuxTextBlock] {
        var blocks: [SupermuxTextBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !joined.isEmpty else { return }
            blocks.append(
                SupermuxTextBlock(index: blocks.count, kind: .paragraph, text: joined)
            )
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            if let block = Self.structuralBlock(from: line) {
                flushParagraph()
                blocks.append(
                    SupermuxTextBlock(index: blocks.count, kind: block.kind, text: block.text)
                )
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    private static func structuralBlock(from line: String) -> SupermuxTextBlock? {
        let indentWidth = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = indentWidth / 2

        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes >= 1, hashes <= 6 {
                let rest = trimmed.dropFirst(hashes)
                if rest.hasPrefix(" ") {
                    return SupermuxTextBlock(
                        index: 0,
                        kind: .heading(level: hashes),
                        text: rest.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        // Rule before bullet so `- - -` is not read as a bullet named "- -".
        let ruleChars = trimmed.filter { !$0.isWhitespace }
        if ruleChars.count >= 3,
           let marker = ruleChars.first, "-*_".contains(marker),
           ruleChars.allSatisfy({ $0 == marker }) {
            return SupermuxTextBlock(index: 0, kind: .rule, text: "")
        }

        if let first = trimmed.first, "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            if rest.hasPrefix(" ") {
                return SupermuxTextBlock(
                    index: 0,
                    kind: .bullet(indent: indent),
                    text: rest.trimmingCharacters(in: .whitespaces)
                )
            }
        }

        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = trimmed.dropFirst(digits.count)
            if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" {
                let rest = afterDigits.dropFirst()
                if rest.hasPrefix(" ") {
                    return SupermuxTextBlock(
                        index: 0,
                        kind: .ordered(marker: "\(digits)\(delimiter)", indent: indent),
                        text: rest.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        if trimmed.hasPrefix(">") {
            return SupermuxTextBlock(
                index: 0,
                kind: .quote,
                text: trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            )
        }
        return nil
    }
}

/// Bounded main-actor cache of parsed markdown and block splits.
///
/// Deliberately not `@Observable`: it never changes observably, so passing it
/// through the environment cannot invalidate transcript rows (the fork's
/// lazy-list snapshot-boundary rule). Cache keys include the text hash, so a
/// streaming message re-parses only itself.
///
/// Render discipline: lookups are called from row `body`s, so a **miss parses
/// and returns immediately but defers the dictionary insert** to a main-actor
/// task that runs after the render pass. Body evaluation therefore performs no
/// stateful writes (the fork's no-writes-from-body rule); the worst case is
/// one redundant parse per row between the miss and the deferred insert.
@MainActor
public final class SupermuxHarnessMarkdownCache {
    private var attributed: [String: AttributedString] = [:]
    private var attributedOrder: [String] = []
    private var segments: [String: [SupermuxProseSegment]] = [:]
    private var segmentOrder: [String] = []
    private var blocks: [String: [SupermuxTextBlock]] = [:]
    private var blockOrder: [String] = []
    private let capacity: Int

    public init(capacity: Int = 800) {
        self.capacity = capacity
    }

    /// Inline-styled attributed text for one markdown block.
    ///
    /// - Parameter baseSize: The unscaled prose size the caller renders at,
    ///   used to pin a matching monospaced face on `` `code` `` runs.
    public func attributedText(
        rowID: String,
        markdown: String,
        baseSize: CGFloat = SupermuxHarnessTokens.body
    ) -> AttributedString {
        let monoSize = GlobalFontMagnification.scaledSize(baseSize)
        let key = "\(rowID)-\(markdown.hashValue)-\(monoSize)"
        if let cached = attributed[key] { return cached }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var rendered = (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
        Self.linkifyBareURLs(in: &rendered)
        Self.monospaceCodeSpans(in: &rendered, size: monoSize)
        let value = rendered
        deferInsert { cache in
            cache.evict(&cache.attributed, order: &cache.attributedOrder)
            if cache.attributed[key] == nil {
                cache.attributed[key] = value
                cache.attributedOrder.append(key)
            }
        }
        return rendered
    }

    public func proseSegments(rowID: String, text: String) -> [SupermuxProseSegment] {
        let key = "\(rowID)-\(text.hashValue)"
        if let cached = segments[key] { return cached }
        let result = SupermuxProseSegmenter().segments(from: text)
        deferInsert { cache in
            cache.evict(&cache.segments, order: &cache.segmentOrder)
            if cache.segments[key] == nil {
                cache.segments[key] = result
                cache.segmentOrder.append(key)
            }
        }
        return result
    }

    public func textBlocks(rowID: String, text: String) -> [SupermuxTextBlock] {
        let key = "\(rowID)-\(text.hashValue)"
        if let cached = blocks[key] { return cached }
        let result = SupermuxTextBlockParser().blocks(from: text)
        deferInsert { cache in
            cache.evict(&cache.blocks, order: &cache.blockOrder)
            if cache.blocks[key] == nil {
                cache.blocks[key] = result
                cache.blockOrder.append(key)
            }
        }
        return result
    }

    /// Runs `mutation` on the main actor *after* the current render pass, so
    /// cache lookups from view bodies never mutate state during rendering.
    private func deferInsert(_ mutation: @escaping (SupermuxHarnessMarkdownCache) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            mutation(self)
        }
    }

    private func evict<Value>(_ storage: inout [String: Value], order: inout [String]) {
        guard storage.count >= capacity, let oldest = order.first else { return }
        storage[oldest] = nil
        order.removeFirst()
    }

    /// Markdown tags inline code with `.code`, and SwiftUI derives its font
    /// from the ambient prose font — which only reaches a fixed-width face
    /// when the prose family has one. Pin the mono face on those runs so
    /// backticked identifiers and paths stay monospaced (remodex's
    /// `monospaceCodeSpans` fix, applied verbatim).
    static func monospaceCodeSpans(in attributed: inout AttributedString, size: CGFloat) {
        let codeFont = Font.system(size: size, design: .monospaced)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = codeFont
        }
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Markdown's inline parser links only `[text](url)` and `<url>`; bare URLs
    /// stay plain text without this.
    private static func linkifyBareURLs(in text: inout AttributedString) {
        let plain = String(text.characters)
        guard let detector = linkDetector, !plain.isEmpty else { return }
        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in detector.matches(in: plain, range: nsRange) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: plain),
                  let attrRange = Range(stringRange, in: text) else { continue }
            if text[attrRange].link == nil {
                text[attrRange].link = url
            }
        }
    }
}

extension EnvironmentValues {
    /// The harness markdown cache, injected by the harness view. Rows fall back
    /// to uncached parsing when absent (previews).
    @Entry public var supermuxHarnessMarkdownCache: SupermuxHarnessMarkdownCache?
}
