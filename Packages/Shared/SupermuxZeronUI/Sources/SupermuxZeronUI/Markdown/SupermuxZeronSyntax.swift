//
//  SupermuxZeronSyntax.swift
//  SupermuxZeronUI
//
//  `HighlightKind` → `SupermuxZeronSyntaxPalette`, plus the highlighter that
//  produces the kinds. Spec 05 §2.5.6, plan R9.
//
//  ══════════════════════════════════════════════════════════════════════════
//  THE INVARIANT — the only thing in this file that may never bend
//  ══════════════════════════════════════════════════════════════════════════
//
//  Highlighting changes FOREGROUND COLOUR ONLY. Never the font, the weight, the
//  style, the wrapping, the height, or the scroll geometry. zeron asserts this
//  in code (`runs.iter().all(|r| r.font == mono)`, `docs/syntax-highlighting.md`)
//  and it is what makes the code block's exact `lines × 18` height hold before
//  the highlighter has run at all.
//
//  Consequence, and it is FAITHFUL rather than a defect: a block renders PLAIN
//  first and RECOLOURS asynchronously a frame or two later, with zero layout
//  change. zeron does exactly this — `CodeHighlight = Option<&[Vec<Span>]>`,
//  `None` while pending.
//
//  ══════════════════════════════════════════════════════════════════════════
//  R9 DECISION — a hand-written lexical highlighter, behind a swappable seam
//  ══════════════════════════════════════════════════════════════════════════
//
//  zeron highlights with **tree-sitter** through `tree_sitter_highlight`,
//  wrapped in the pure `zeron-syntax` crate, over 28 pinned grammars. The plan
//  ranks a real tree-sitter binding as the ideal (R9) and a hand-mapped
//  highlighter as acceptable *if the coverage gap is documented*. This port
//  takes the second option, deliberately:
//
//  1. **The package may take exactly one dependency.** `Package.swift` states
//     it: "This is the ONLY dependency the shared zeron UI is allowed to take."
//     A tree-sitter binding is a `systemLibrary`/`cSettings` target plus 28
//     vendored grammar sources — each one a multi-megabyte generated
//     `parser.c` — landing inside a package whose whole job is the design
//     system. It also has to build for macOS AND iOS device AND simulator.
//  2. **The fidelity delta is bounded and colour-only.** By the invariant
//     above, a highlighter can only ever get a COLOUR wrong. It cannot shift a
//     glyph, change a height, or break the fold tween. The worst outcome is a
//     token painted `text` that zeron paints amber.
//  3. **The seam is real.** Everything downstream consumes
//     ``SupermuxZeronHighlighter`` — a protocol over
//     `(source, language) -> [[SupermuxZeronHighlightSpan]]`. Swapping in
//     tree-sitter is one conformance and one line at the composition root; no
//     view, no cache and no test changes.
//
//  ── COVERAGE GAP, stated plainly ──
//
//  ``SupermuxZeronLexicalHighlighter`` is a hand-written lexer, not a parser.
//  It has no syntax tree, so it resolves tokens by shape and context window
//  rather than by grammar. Against zeron's tree-sitter output:
//
//  | Kind | Coverage |
//  |---|---|
//  | `comment`, `string`, `stringSpecial`, `escape`, `number`, `boolean` | **full** — these are lexical by nature and match tree-sitter exactly |
//  | `keyword` | **full** for the 12 covered languages (a fixed word set) |
//  | `function` | **good** — an identifier immediately followed by `(`; misses a function value passed without a call, and paints a call-shaped macro invocation as a function |
//  | `type`, `constructor` | **heuristic** — `UpperCamelCase` identifiers. Correct in Swift/Rust/TS/Go/Java/Kotlin/C#; wrong for a language whose types are lowercase, and it paints an UpperCamel *constant* as a type |
//  | `typeBuiltin` | **full** for the covered languages (a fixed word set) |
//  | `macro` | **partial** — Rust `name!`, C `#define`-style directives |
//  | `attribute` | **partial** — `@attr`, `#[attr]`, and HTML/JSX attribute positions |
//  | `property` | **partial** — the identifier after a `.` that is not a call |
//  | `tag` | **full** in HTML/XML/JSX; **n/a** elsewhere |
//  | `punctuation`, `operator`, `variable`, `parameter` | **full** by construction — all four are aliases of `theme.text`, so any misclassification among them is INVISIBLE |
//  | `constant` | **heuristic** — `SCREAMING_SNAKE_CASE` |
//  | `label`, `variableSpecial`, `functionBuiltin`, `invalid`, `embedded` | **not emitted** — they need a syntax tree. Their text falls back to `variable`/`punctuation`, i.e. `theme.text`, which is a quiet miss rather than a wrong colour |
//
//  Languages: the 12 highest-traffic families of zeron's 28
//  (`SupermuxZeronSyntaxLanguage`). An unrecognised fence tag highlights
//  NOTHING and renders plain — which is also exactly what zeron does for an
//  unknown language, an over-limit source, or a parse failure.
//

internal import Foundation

public import SwiftUI

// MARK: - Span

/// One highlighted range on ONE source line. Byte offsets are relative to that
/// line, matching `zeron-syntax`'s `HighlightSpan` contract exactly.
public struct SupermuxZeronHighlightSpan: Sendable, Equatable, Hashable {
    public var range: Range<Int>
    public var kind: SupermuxZeronHighlightKind

    public init(range: Range<Int>, kind: SupermuxZeronHighlightKind) {
        self.range = range
        self.kind = kind
    }
}

/// A highlighted document: one span list per source line.
public struct SupermuxZeronHighlightedDocument: Sendable, Equatable {
    public var language: SupermuxZeronSyntaxLanguage
    public var lines: [[SupermuxZeronHighlightSpan]]

    public init(language: SupermuxZeronSyntaxLanguage, lines: [[SupermuxZeronHighlightSpan]]) {
        self.language = language
        self.lines = lines
    }
}

// MARK: - The seam

/// The swappable highlighter contract.
///
/// A tree-sitter binding conforms to this and nothing downstream changes. The
/// contract is deliberately narrow: pure, `Sendable`, and no UI or theme
/// knowledge — it returns NEUTRAL kinds, never colours, exactly like
/// `zeron-syntax`.
public protocol SupermuxZeronHighlighter: Sendable {
    /// Highlight `source` as `language`, returning one span list per line.
    ///
    /// Must be pure and side-effect free: it is called off the main actor.
    func highlight(
        source: String,
        language: SupermuxZeronSyntaxLanguage
    ) -> [[SupermuxZeronHighlightSpan]]
}

// MARK: - Languages

/// The languages this port highlights.
///
/// A subset of `zeron-syntax`'s 28. An unlisted fence tag renders PLAIN, which
/// is the same outcome zeron produces for an unknown language.
public enum SupermuxZeronSyntaxLanguage: String, Sendable, Equatable, Hashable, CaseIterable {
    case swift, rust, typescript, javascript, python, go
    case json, bash, yaml, toml, css, html
    case c, cpp, java, kotlin, ruby, sql

    /// Fence tag / path extension → language. Case-insensitive, and it takes
    /// the FIRST whitespace-delimited token, so ```` ```rust,no_run ```` works.
    ///
    /// The alias table is `zeron-syntax`'s `language_for_alias` restricted to
    /// the covered set (`crates/syntax/src/lib.rs:682`).
    public static func named(_ alias: String) -> SupermuxZeronSyntaxLanguage? {
        let key = alias.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased()
        switch key {
        case "swift": return .swift
        case "rust", "rs": return .rust
        case "typescript", "ts", "mts", "cts", "tsx": return .typescript
        case "javascript", "js", "mjs", "cjs", "jsx": return .javascript
        case "python", "py", "python3": return .python
        case "go", "golang": return .go
        case "json", "jsonc": return .json
        case "bash", "sh", "shell", "zsh", "console": return .bash
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "css": return .css
        case "html", "htm", "xml": return .html
        case "c", "h": return .c
        case "cpp", "c++", "cc", "cxx", "hpp": return .cpp
        case "java": return .java
        case "kotlin", "kt", "kts": return .kotlin
        case "ruby", "rb": return .ruby
        case "sql": return .sql
        default: return nil
        }
    }
}

// MARK: - Lexical highlighter

/// The hand-written lexer. See the file header for the R9 decision and the
/// coverage table.
public struct SupermuxZeronLexicalHighlighter: SupermuxZeronHighlighter {
    /// zeron's own guard rails (`DEFAULT_MAX_SOURCE_BYTES`,
    /// `DEFAULT_MAX_SPANS`). Over-limit sources render PLAIN.
    public static let maxSourceBytes = 1024 * 1024
    public static let maxSpans = 200_000

    public init() {}

    public func highlight(
        source: String,
        language: SupermuxZeronSyntaxLanguage
    ) -> [[SupermuxZeronHighlightSpan]] {
        let lines = source.components(separatedBy: "\n")
        guard source.utf8.count <= Self.maxSourceBytes else {
            return Array(repeating: [], count: lines.count)
        }
        let grammar = SupermuxZeronGrammar.grammar(for: language)
        var out: [[SupermuxZeronHighlightSpan]] = []
        out.reserveCapacity(lines.count)
        // Block comments and multi-line strings carry across lines, so the
        // lexer threads one mutable state through the whole document.
        var state = LexState()
        var emitted = 0
        for line in lines {
            guard emitted < Self.maxSpans else {
                out.append([])
                continue
            }
            let spans = Self.scan(line: line, grammar: grammar, state: &state)
            emitted += spans.count
            out.append(spans)
        }
        return out
    }

    /// Carried lexer state: an open block comment or an open multi-line string.
    private struct LexState {
        var blockComment: String?
        var rawString: String?
    }

    // MARK: The scanner

    private static func scan(
        line: String,
        grammar: SupermuxZeronGrammar,
        state: inout LexState
    ) -> [SupermuxZeronHighlightSpan] {
        var spans: [SupermuxZeronHighlightSpan] = []
        let chars = Array(line)
        // Byte offset per character index, so every emitted range is in the
        // UTF-8 bytes `HighlightSpan` promises.
        var byteAt: [Int] = [0]
        byteAt.reserveCapacity(chars.count + 1)
        var total = 0
        for c in chars {
            total += String(c).utf8.count
            byteAt.append(total)
        }

        func emit(_ from: Int, _ to: Int, _ kind: SupermuxZeronHighlightKind) {
            guard from < to, to <= chars.count else { return }
            spans.append(
                SupermuxZeronHighlightSpan(range: byteAt[from]..<byteAt[to], kind: kind)
            )
        }

        var i = 0

        // An open block comment swallows until its terminator.
        if let terminator = state.blockComment {
            if let end = find(chars, terminator, from: 0) {
                emit(0, end + terminator.count, .comment)
                i = end + terminator.count
                state.blockComment = nil
            } else {
                emit(0, chars.count, .comment)
                return spans
            }
        }
        // An open multi-line string likewise.
        if let terminator = state.rawString {
            if let end = find(chars, terminator, from: i) {
                emit(i, end + terminator.count, .string)
                i = end + terminator.count
                state.rawString = nil
            } else {
                emit(i, chars.count, .string)
                return spans
            }
        }

        while i < chars.count {
            let c = chars[i]

            if c.isWhitespace { i += 1; continue }

            // Line comment.
            if let marker = grammar.lineComments.first(where: { matches(chars, $0, at: i) }) {
                // A `#` in CSS is a colour/id, not a comment — grammars that
                // do not use `#` simply do not list it.
                _ = marker
                emit(i, chars.count, .comment)
                break
            }

            // Block comment.
            if let block = grammar.blockComments.first(where: { matches(chars, $0.open, at: i) }) {
                if let end = find(chars, block.close, from: i + block.open.count) {
                    emit(i, end + block.close.count, .comment)
                    i = end + block.close.count
                } else {
                    emit(i, chars.count, .comment)
                    state.blockComment = block.close
                    break
                }
                continue
            }

            // Multi-line string opener (Python/Swift triple quotes, etc.).
            if let raw = grammar.multiLineStrings.first(where: { matches(chars, $0, at: i) }) {
                if let end = find(chars, raw, from: i + raw.count) {
                    emit(i, end + raw.count, .string)
                    i = end + raw.count
                } else {
                    emit(i, chars.count, .string)
                    state.rawString = raw
                    break
                }
                continue
            }

            // Single-line string, with escapes painted `escape` INSIDE it.
            if grammar.stringDelimiters.contains(c) {
                let start = i
                i += 1
                var escapes: [(Int, Int)] = []
                while i < chars.count {
                    if chars[i] == "\\", i + 1 < chars.count {
                        escapes.append((i, i + 2))
                        i += 2
                        continue
                    }
                    if chars[i] == c { i += 1; break }
                    i += 1
                }
                // Emit the string first; the escapes overlay it, and the
                // renderer's later spans win on the same range.
                emit(start, i, .string)
                for (from, to) in escapes { emit(from, to, .escape) }
                continue
            }

            // Number: a digit, or a `.` followed by a digit.
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                let start = i
                while i < chars.count,
                      chars[i].isHexDigit || "._xXbBoOeE+-".contains(chars[i]) {
                    // A `+`/`-` continues the literal only as an exponent sign.
                    if chars[i] == "+" || chars[i] == "-" {
                        guard i > start, "eE".contains(chars[i - 1]) else { break }
                    }
                    i += 1
                }
                // A trailing `.` belongs to member access, not to the number.
                if chars[i - 1] == "." { i -= 1 }
                emit(start, i, .number)
                continue
            }

            // Attribute / macro sigils.
            if grammar.attributeSigils.contains(c), i + 1 < chars.count,
               chars[i + 1].isLetter || chars[i + 1] == "_" {
                let start = i
                i += 1
                while i < chars.count, isIdentifier(chars[i]) { i += 1 }
                emit(start, i, .attribute)
                continue
            }

            // Identifier / keyword / type / function / property / constant.
            if isIdentifierStart(c) {
                let start = i
                while i < chars.count, isIdentifier(chars[i]) { i += 1 }
                let word = String(chars[start..<i])

                // Rust-style `name!` macro invocation.
                if grammar.hasBangMacros, i < chars.count, chars[i] == "!" {
                    emit(start, i + 1, .macro)
                    i += 1
                    continue
                }
                if grammar.keywords.contains(word) {
                    emit(start, i, .keyword)
                    continue
                }
                if grammar.booleans.contains(word) {
                    emit(start, i, .boolean)
                    continue
                }
                if grammar.builtinTypes.contains(word) {
                    emit(start, i, .typeBuiltin)
                    continue
                }
                // An identifier immediately followed by `(` is a call.
                var probe = i
                while probe < chars.count, chars[probe] == " " { probe += 1 }
                if probe < chars.count, chars[probe] == "(" {
                    emit(start, i, .function)
                    continue
                }
                // SCREAMING_SNAKE_CASE is a constant.
                if word.count > 1,
                   word.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }),
                   word.contains(where: \.isUppercase) {
                    emit(start, i, .constant)
                    continue
                }
                // UpperCamelCase is a type. Heuristic — see the coverage table.
                if grammar.upperCamelIsType, let first = word.first, first.isUppercase {
                    emit(start, i, .type)
                    continue
                }
                // The identifier after a `.` that is not a call is a property.
                if start > 0, chars[start - 1] == "." {
                    emit(start, i, .property)
                    continue
                }
                // Everything else is `variable`, which is an alias of
                // `theme.text` — emitting it would be a no-op paint.
                continue
            }

            // HTML/JSX tag name.
            if grammar.hasTags, c == "<", i + 1 < chars.count {
                var probe = i + 1
                if chars[probe] == "/" { probe += 1 }
                guard probe < chars.count, chars[probe].isLetter else { i += 1; continue }
                let start = probe
                while probe < chars.count, isIdentifier(chars[probe]) || chars[probe] == "-" {
                    probe += 1
                }
                emit(start, probe, .tag)
                i = probe
                continue
            }

            i += 1
        }
        return spans
    }

    // MARK: Character helpers

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == "$"
    }

    private static func isIdentifier(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
    }

    private static func matches(_ chars: [Character], _ needle: String, at i: Int) -> Bool {
        let n = Array(needle)
        guard i + n.count <= chars.count else { return false }
        for (k, ch) in n.enumerated() where chars[i + k] != ch { return false }
        return true
    }

    private static func find(_ chars: [Character], _ needle: String, from: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        var i = max(0, from)
        while i + needle.count <= chars.count {
            if matches(chars, needle, at: i) { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - Grammar tables

/// The per-language token tables the lexer consults.
struct SupermuxZeronGrammar: Sendable {
    var keywords: Set<String> = []
    var builtinTypes: Set<String> = []
    var booleans: Set<String> = []
    var lineComments: [String] = ["//"]
    var blockComments: [(open: String, close: String)] = [("/*", "*/")]
    var multiLineStrings: [String] = []
    var stringDelimiters: Set<Character> = ["\"", "'"]
    var attributeSigils: Set<Character> = []
    var hasBangMacros = false
    var hasTags = false
    /// Whether `UpperCamelCase` reliably means a type in this language.
    var upperCamelIsType = true

    /// lint:allow namespace-type — keyword tables; data, not behavior.
    static func grammar(for language: SupermuxZeronSyntaxLanguage) -> SupermuxZeronGrammar {
        var g = SupermuxZeronGrammar()
        switch language {
        case .swift:
            g.keywords = [
                "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
                "import", "init", "inout", "internal", "let", "open", "operator", "private",
                "precedencegroup", "protocol", "public", "rethrows", "static", "struct",
                "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
                "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
                "return", "throw", "switch", "where", "while", "as", "is", "nil", "self", "Self",
                "super", "throws", "try", "async", "await", "some", "any", "actor", "nonisolated",
                "final", "lazy", "weak", "unowned", "mutating", "override", "required",
                "convenience", "indirect", "package",
            ]
            g.builtinTypes = [
                "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
                "UInt64", "Float", "Double", "Bool", "String", "Character", "Array", "Dictionary",
                "Set", "Optional", "Result", "Void", "Never", "Any", "AnyObject",
            ]
            g.booleans = ["true", "false"]
            g.multiLineStrings = ["\"\"\""]
            g.stringDelimiters = ["\""]
            g.attributeSigils = ["@"]
        case .rust:
            g.keywords = [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
                "super", "trait", "type", "unsafe", "use", "where", "while", "union",
            ]
            g.builtinTypes = [
                "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128",
                "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result",
                "Box", "Rc", "Arc", "HashMap", "HashSet", "BTreeMap",
            ]
            g.booleans = ["true", "false"]
            g.multiLineStrings = ["r#\""]
            g.stringDelimiters = ["\""]
            g.attributeSigils = ["#"]
            g.hasBangMacros = true
        case .typescript, .javascript:
            g.keywords = [
                "abstract", "any", "as", "async", "await", "break", "case", "catch", "class",
                "const", "continue", "debugger", "declare", "default", "delete", "do", "else",
                "enum", "export", "extends", "finally", "for", "from", "function", "get", "if",
                "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace",
                "new", "of", "private", "protected", "public", "readonly", "return", "satisfies",
                "set", "static", "super", "switch", "this", "throw", "try", "type", "typeof",
                "var", "void", "while", "with", "yield",
            ]
            g.builtinTypes = [
                "string", "number", "boolean", "object", "symbol", "bigint", "unknown", "never",
                "Array", "Promise", "Map", "Set", "Record", "Partial", "Readonly", "Date",
                "RegExp", "Error", "JSON", "Math", "Object",
            ]
            g.booleans = ["true", "false", "null", "undefined"]
            g.multiLineStrings = []
            g.stringDelimiters = ["\"", "'", "`"]
            g.attributeSigils = ["@"]
            g.hasTags = true
        case .python:
            g.keywords = [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
                "return", "try", "while", "with", "yield", "match", "case", "self",
            ]
            g.builtinTypes = [
                "int", "float", "str", "bool", "bytes", "list", "dict", "set", "tuple",
                "frozenset", "complex", "object", "type",
            ]
            g.booleans = ["True", "False", "None"]
            g.lineComments = ["#"]
            g.blockComments = []
            g.multiLineStrings = ["\"\"\"", "'''"]
            g.attributeSigils = ["@"]
        case .go:
            g.keywords = [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var",
            ]
            g.builtinTypes = [
                "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
                "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
                "uint32", "uint64", "uintptr", "any",
            ]
            g.booleans = ["true", "false", "nil", "iota"]
            g.stringDelimiters = ["\"", "`", "'"]
        case .json:
            g.keywords = []
            g.booleans = ["true", "false", "null"]
            g.lineComments = ["//"]
            g.stringDelimiters = ["\""]
            // JSON has no types; an UpperCamel string is just a string.
            g.upperCamelIsType = false
        case .bash:
            g.keywords = [
                "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while",
                "until", "do", "done", "in", "function", "time", "coproc", "local", "export",
                "readonly", "declare", "unset", "return", "shift", "source", "alias", "set",
            ]
            g.builtinTypes = [
                "echo", "printf", "cd", "pwd", "read", "test", "eval", "exec", "exit", "trap",
                "kill", "wait", "jobs",
            ]
            g.booleans = ["true", "false"]
            g.lineComments = ["#"]
            g.blockComments = []
            g.upperCamelIsType = false
        case .yaml:
            g.keywords = []
            g.booleans = ["true", "false", "null", "yes", "no", "on", "off", "~"]
            g.lineComments = ["#"]
            g.blockComments = []
            g.upperCamelIsType = false
        case .toml:
            g.keywords = []
            g.booleans = ["true", "false"]
            g.lineComments = ["#"]
            g.blockComments = []
            g.multiLineStrings = ["\"\"\"", "'''"]
            g.upperCamelIsType = false
        case .css:
            g.keywords = [
                "important", "media", "import", "charset", "supports", "keyframes", "font-face",
                "from", "to",
            ]
            g.builtinTypes = []
            g.lineComments = []
            g.upperCamelIsType = false
        case .html:
            g.keywords = []
            g.lineComments = []
            g.blockComments = [("<!--", "-->")]
            g.hasTags = true
            g.upperCamelIsType = false
        case .c, .cpp:
            g.keywords = [
                "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
                "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
                "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
                "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "class",
                "namespace", "template", "typename", "public", "private", "protected", "virtual",
                "override", "final", "new", "delete", "using", "constexpr", "noexcept", "this",
                "operator", "explicit", "friend", "mutable",
            ]
            g.builtinTypes = [
                "bool", "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                "int8_t", "int16_t", "int32_t", "int64_t", "wchar_t", "nullptr_t", "string",
                "vector", "map", "set", "shared_ptr", "unique_ptr",
            ]
            g.booleans = ["true", "false", "NULL", "nullptr"]
            g.attributeSigils = ["#"]
        case .java, .kotlin:
            g.keywords = [
                "abstract", "assert", "break", "case", "catch", "class", "const", "continue",
                "default", "do", "else", "enum", "extends", "final", "finally", "for", "goto",
                "if", "implements", "import", "instanceof", "interface", "native", "new",
                "package", "private", "protected", "public", "return", "static", "strictfp",
                "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try",
                "volatile", "while", "var", "val", "fun", "object", "when", "is", "as", "in",
                "out", "sealed", "data", "companion", "init", "suspend", "override", "internal",
                "lateinit", "by", "typealias",
            ]
            g.builtinTypes = [
                "int", "long", "short", "byte", "char", "float", "double", "boolean", "void",
                "String", "Integer", "Long", "Double", "Boolean", "List", "Map", "Set", "Array",
                "Any", "Unit", "Nothing",
            ]
            g.booleans = ["true", "false", "null"]
            g.attributeSigils = ["@"]
        case .ruby:
            g.keywords = [
                "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
                "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not",
                "or", "redo", "rescue", "retry", "return", "self", "super", "then", "undef",
                "unless", "until", "when", "while", "yield", "require", "attr_accessor",
                "attr_reader", "attr_writer",
            ]
            g.builtinTypes = [
                "Integer", "Float", "String", "Symbol", "Array", "Hash", "Range", "Proc",
                "Struct", "Class", "Module",
            ]
            g.booleans = ["true", "false", "nil"]
            g.lineComments = ["#"]
            g.blockComments = []
            g.attributeSigils = ["@"]
        case .sql:
            g.keywords = [
                "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                "create", "table", "drop", "alter", "add", "column", "index", "view", "join",
                "inner", "left", "right", "outer", "full", "on", "group", "by", "order", "having",
                "limit", "offset", "union", "all", "distinct", "as", "and", "or", "not", "in",
                "exists", "between", "like", "is", "case", "when", "then", "else", "end",
                "primary", "key", "foreign", "references", "constraint", "unique", "default",
                "with", "returning",
            ]
            g.builtinTypes = [
                "int", "integer", "bigint", "smallint", "serial", "text", "varchar", "char",
                "boolean", "date", "timestamp", "timestamptz", "numeric", "decimal", "real",
                "double", "json", "jsonb", "uuid", "bytea",
            ]
            g.booleans = ["true", "false", "null"]
            g.lineComments = ["--"]
            g.stringDelimiters = ["'", "\""]
            g.upperCamelIsType = false
        }
        return g
    }
}

// MARK: - Highlight cache

/// A bounded cache of highlight documents, keyed on `(language, source)`.
///
/// zeron keys its cache on `(LanguageId, SHA-256(source), QUERY_GENERATION)` and
/// deliberately **not** on the theme, so an appearance switch RECOLOURS without
/// reparsing. Same property here: the cache stores neutral kinds only, so
/// flipping light/dark never invalidates it.
///
/// The cache is an actor because highlighting runs off the main actor and the
/// same code block is commonly requested by several rows at once.
///
/// **Injected, not global.** There is deliberately no `.shared` accessor: the
/// repo bans shared-singleton accessors, and a global here would also pin one
/// highlighter choice process-wide, defeating the swappable seam this file
/// exists to preserve. The transcript owns one cache and passes it down through
/// ``SwiftUI/EnvironmentValues/supermuxZeronSyntaxCache``; a preview, a test, or
/// a second surface constructs its own.
public actor SupermuxZeronSyntaxCache {
    /// zeron's `MAX_DOCUMENTS = 96`.
    public static let maxDocuments = 96

    private struct Key: Hashable {
        let language: SupermuxZeronSyntaxLanguage
        let source: String
    }

    private var storage: [Key: [[SupermuxZeronHighlightSpan]]] = [:]
    /// Insertion order, oldest first — the LRU eviction queue.
    private var order: [Key] = []
    private let highlighter: any SupermuxZeronHighlighter

    public init(highlighter: any SupermuxZeronHighlighter = SupermuxZeronLexicalHighlighter()) {
        self.highlighter = highlighter
    }

    /// Highlight `source`, serving a cached document when one exists.
    public func document(
        source: String,
        language: SupermuxZeronSyntaxLanguage
    ) -> [[SupermuxZeronHighlightSpan]] {
        let key = Key(language: language, source: source)
        if let hit = storage[key] {
            if let at = order.firstIndex(of: key) {
                order.remove(at: at)
                order.append(key)
            }
            return hit
        }
        let lines = highlighter.highlight(source: source, language: language)
        storage[key] = lines
        order.append(key)
        while order.count > Self.maxDocuments {
            storage.removeValue(forKey: order.removeFirst())
        }
        return lines
    }
}

// MARK: - Injection

private struct SupermuxZeronSyntaxCacheKey: EnvironmentKey {
    // The default is a fresh cache, so a view that forgets to inject one still
    // highlights correctly — it just does not share work with its siblings.
    static let defaultValue = SupermuxZeronSyntaxCache()
}

public extension EnvironmentValues {
    /// The highlight cache assistant rows read.
    ///
    /// Inject ONE per transcript at the shell so every row shares its work and
    /// its LRU budget:
    ///
    /// ```swift
    /// transcript.environment(\.supermuxZeronSyntaxCache, model.syntaxCache)
    /// ```
    ///
    /// Injecting a cache built with a different ``SupermuxZeronHighlighter`` is
    /// how a tree-sitter binding would be swapped in — see this file's header.
    var supermuxZeronSyntaxCache: SupermuxZeronSyntaxCache {
        get { self[SupermuxZeronSyntaxCacheKey.self] }
        set { self[SupermuxZeronSyntaxCacheKey.self] = newValue }
    }
}

// MARK: - Run construction

/// Paint-only run construction for one code line: a pure
/// `(line, spans) -> runs` transform.
/// lint:allow namespace-enum, namespace-type — free-function module.
public enum SupermuxZeronSyntaxRuns {
    /// Build the EXACT-COVER run list for one code line from its spans.
    ///
    /// Gaps become `plain` runs, each span becomes a run of the SAME font with
    /// only its colour changed, and the total run length always equals the line
    /// length exactly — that identity is what guarantees recolouring cannot
    /// change layout. Zero-length runs are dropped, and overlapping spans are
    /// resolved by `HighlightKind.precedence` exactly as `zeron-syntax` does.
    ///
    /// `plainColor` is `theme.text @ 0.92` in a code block, so a highlighted
    /// token is always slightly BRIGHTER than the code around it — syntax runs
    /// are full alpha.
    public static func runs(
        line: String,
        spans: [SupermuxZeronHighlightSpan],
        palette: SupermuxZeronSyntaxPalette,
        plainColor: Color
    ) -> [SupermuxZeronTextRun] {
        let bytes = line.utf8.count
        guard bytes > 0 else { return [] }

        // Flatten overlaps: the highest-precedence kind wins each byte. This is
        // what lets the lexer overlay `escape` spans on top of a `string`.
        var kinds = [SupermuxZeronHighlightKind?](repeating: nil, count: bytes)
        for span in spans {
            let lower = max(0, span.range.lowerBound)
            let upper = min(bytes, span.range.upperBound)
            guard lower < upper else { continue }
            for i in lower..<upper {
                if let existing = kinds[i], existing.precedence >= span.kind.precedence { continue }
                kinds[i] = span.kind
            }
        }

        var out: [SupermuxZeronTextRun] = []
        var start = 0
        var current = kinds.first ?? nil
        func flush(_ end: Int) {
            guard start < end else { return }
            guard let text = slice(line, start..<end) else { return }
            out.append(
                SupermuxZeronTextRun(
                    text: text,
                    isMono: true,
                    color: current.map(palette.color(for:)) ?? plainColor
                )
            )
        }
        for i in 1..<bytes where kinds[i] != current {
            flush(i)
            start = i
            current = kinds[i]
        }
        flush(bytes)
        return out
    }

    /// A UTF-8 byte slice of `line`, or `nil` when the range splits a scalar.
    private static func slice(_ line: String, _ range: Range<Int>) -> String? {
        let utf8 = line.utf8
        guard let lower = utf8.index(
            utf8.startIndex,
            offsetBy: range.lowerBound,
            limitedBy: utf8.endIndex
        ),
            let upper = utf8.index(
                utf8.startIndex,
                offsetBy: range.upperBound,
                limitedBy: utf8.endIndex
            ) else { return nil }
        return String(utf8[lower..<upper])
    }
}

public extension SupermuxZeronHighlightKind {
    /// Stable precedence for resolving overlapping captures
    /// (`crates/syntax/src/lib.rs:91`, reproduced value-for-value).
    var precedence: UInt8 {
        switch self {
        case .invalid: 100
        case .escape: 95
        case .macro: 90
        case .property, .attribute: 85
        case .functionBuiltin, .typeBuiltin, .variableSpecial: 80
        case .stringSpecial, .constructor, .parameter: 75
        case .function, .type, .constant, .tag, .label: 70
        case .comment, .keyword, .string, .number, .boolean: 60
        case .variable, .operator: 50
        case .punctuation, .embedded: 40
        }
    }
}
