//
//  SupermuxZeronWorkingTrailer.swift
//  SupermuxZeronUI
//
//  The working indicator, INSIDE the conversation flow. Spec 02 §2.6, spec 07 §5.3.
//
//  It rides under the LAST row's content and above that row's bottom-clearance
//  pad, so it reads as part of the streaming reply and scrolls away with it.
//  zeron moved it out of the shell's status strip for exactly that reason (a
//  user request quoted in `transcript.rs:2641-2646`).
//
//  | Property         | Value                                                  |
//  |------------------|--------------------------------------------------------|
//  | container        | row, centred, gap 8, padding-top 10, inherited 11 pt    |
//  | spinner          | `gradient_spinner(cell 2.5)` → 10 × 10 pt               |
//  | word             | 12 pt, `textMuted`, `"{word}…"`                          |
//  | elapsed          | 11 pt, `textFaint`, `"{n}s"` / `"{m}m {s}s"`             |
//
//  ── The flavour vocabulary is zeron's, verbatim ──
//
//  Twenty words from `transcript.rs:1109-1129`, rotating every 7 s, indexed
//  `words[(fnv1a(sessionKey) + elapsedSecs / 7) % 20]` — deterministic per
//  session, so two devices watching the same run show the same word.
//
//  ── The "Sending…" bridge ──
//
//  During the send→turn window the session's `startedAt` still belongs to the
//  PREVIOUS turn, so a timer based on the send counted the round-trip and then
//  restarted when the turn actually began (user report). The bridge replaces the
//  word with the literal `"Sending"` and OMITS the timer entirely; the word and
//  the timer both start with the turn.
//

public import SwiftUI

internal import Foundation

/// Spinner + rotating flavour word + elapsed timer.
///
/// Immutable values only. `elapsedSeconds` is passed in rather than derived from
/// a live clock inside `body`, because a function called from `body` must not
/// write state and a per-view timer would reintroduce the R12 CPU problem — the
/// shared pulse clock already ticks this view at 30 fps through the spinner, and
/// the host recomputes the elapsed value on that cadence.
public struct SupermuxZeronWorkingTrailer: View {
    /// The deterministic per-session rotation seed, `fnv1a(sessionKey)`.
    private let flavourSeed: UInt64
    /// Seconds since the turn started. Ignored while ``isSending``.
    private let elapsedSeconds: Int
    /// The send→turn bridge: shows `"Sending…"` and hides the timer.
    private let isSending: Bool
    private let theme: SupermuxZeronTheme

    public init(
        flavourSeed: UInt64,
        elapsedSeconds: Int,
        isSending: Bool,
        theme: SupermuxZeronTheme
    ) {
        self.flavourSeed = flavourSeed
        self.elapsedSeconds = elapsedSeconds
        self.isSending = isSending
        self.theme = theme
    }

    public var body: some View {
        HStack(spacing: SupermuxZeronMetrics.Loaders.trailerGap) {
            SupermuxZeronGradientSpinner(leaseID: "working-indicator")
            Text(verbatim: "\(word)…")
                .font(SupermuxZeronFonts.sans(size: SupermuxZeronMetrics.Loaders.trailerWordSize))
                .foregroundStyle(theme.textMuted)
                .lineLimit(1)
            if !isSending {
                // NO `.monospacedDigit()`. On a custom face that modifier does
                // not apply Geist's own `tnum` feature — it substitutes the
                // SYSTEM monospaced-digit face outright (measured: the run comes
                // back as `.SFNS-Regular` at 39.596 pt where Geist renders
                // 30.129), so the one number in the transcript would be set in
                // San Francisco next to Geist text. zeron sets no numeric
                // feature here at all; the elapsed value simply inherits the
                // trailer's font (`transcript.rs:2694-2698`), and a 1 pt reflow
                // once a second on a left-aligned trailing element is invisible.
                Text(verbatim: Self.formatElapsed(elapsedSeconds))
                    .font(
                        SupermuxZeronFonts.sans(
                            size: SupermuxZeronMetrics.Loaders.trailerElapsedSize
                        )
                    )
                    .foregroundStyle(theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SupermuxZeronMetrics.Loaders.trailerTopPad)
        .accessibilityElement(children: .combine)
    }

    private var word: String {
        isSending
            ? Self.sendingWord
            : Self.flavourWord(seed: flavourSeed, elapsedSeconds: elapsedSeconds)
    }

    // MARK: - Flavour vocabulary

    /// zeron's `FLAVOUR_WORDS` (`transcript.rs:1109-1129`), in order.
    ///
    /// **Localized**, unlike the timestamp format: these are ordinary
    /// user-facing copy, not a hardcoded date pattern. The rotation index is
    /// computed over the array, so a translation that reorders nothing keeps the
    /// same determinism.
    public static let flavourWords: [String] = [
        String(localized: "supermux.zeron.flavour.thinking", defaultValue: "Thinking", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.pondering", defaultValue: "Pondering", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.scheming", defaultValue: "Scheming", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.brewing", defaultValue: "Brewing", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.weaving", defaultValue: "Weaving", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.tinkering", defaultValue: "Tinkering", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.musing", defaultValue: "Musing", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.composing", defaultValue: "Composing", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.sifting", defaultValue: "Sifting", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.untangling", defaultValue: "Untangling", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.distilling", defaultValue: "Distilling", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.sketching", defaultValue: "Sketching", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.plotting", defaultValue: "Plotting", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.riffing", defaultValue: "Riffing", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.combobulating", defaultValue: "Combobulating", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.percolating", defaultValue: "Percolating", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.marinating", defaultValue: "Marinating", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.noodling", defaultValue: "Noodling", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.puzzling", defaultValue: "Puzzling", bundle: .supermuxZeronUI),
        String(localized: "supermux.zeron.flavour.conjuring", defaultValue: "Conjuring", bundle: .supermuxZeronUI),
    ]

    /// The literal `"Sending"` bridge word.
    public static let sendingWord = String(
        localized: "supermux.zeron.flavour.sending",
        defaultValue: "Sending",
        bundle: .supermuxZeronUI
    )

    /// `FLAVOUR_WORDS[(seed + elapsed / 7) % 20]`.
    public static func flavourWord(seed: UInt64, elapsedSeconds: Int) -> String {
        let step = UInt64(max(elapsedSeconds, 0) / SupermuxZeronMetrics.Loaders.flavourRotateSecs)
        let index = Int((seed &+ step) % UInt64(flavourWords.count))
        return flavourWords[index]
    }

    /// zeron's `flavour_seed`: FNV-1a over the session key's UTF-8 bytes.
    ///
    /// The offset basis and prime are the 64-bit FNV-1a constants, matching the
    /// data layer's own fingerprint hash so a seed computed on either side of
    /// the wire agrees.
    public static func flavourSeed(sessionKey: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sessionKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    // MARK: - Elapsed

    /// `format_elapsed` (`transcript.rs:1160-1167`): `"{s}s"` under a minute,
    /// otherwise `"{m}m {s}s"`.
    public static func formatElapsed(_ seconds: Int) -> String {
        let value = max(seconds, 0)
        if value < 60 { return "\(value)s" }
        return "\(value / 60)m \(value % 60)s"
    }
}
