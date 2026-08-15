/// The shared zeron/comet design system, ported 1:1 to SwiftUI for macOS 14+ and iOS 18+.
///
/// zeron's chat pane is a single visual system — one 44-token palette, one chip geometry, one
/// markdown renderer, one diff body. Porting it separately into `SupermuxKit` (macOS) and
/// `SupermuxMobileUI` (iOS) guarantees drift, so both platforms mount the views in this package
/// and own only their platform shell (scroll host, hover, popover-vs-sheet, safe areas).
///
/// Layout of `Sources/SupermuxZeronUI/`:
///
/// | Directory | Contents |
/// |---|---|
/// | `Theme/` | Tokens, metrics, the cubic-bezier solver, fonts, glass, edge fade |
/// | `Motion/` | Pulse clock, stick spring, fold tween, streaming veil |
/// | `Icons/` | The vendored Solar icon set and its template tinting |
/// | `Loaders/` | The gradient spinner |
/// | `Rows/` | Row dispatch, row box, user bubble, assistant/thinking/notice rows |
/// | `Chips/` | Tool groups, tool chips, chip details, group summaries |
/// | `Diff/` | The inline diff body |
/// | `Markdown/` | Block layout, the TextKit renderer, code blocks, syntax, streaming mend |
/// | `Composer/` | The composer pill, actions row, trigger chips, slash menu, status strip |
/// | `Pickers/` | The model/effort picker card |
/// | `Empty/` | The empty canvas states |
/// | `Resources/` | `Fonts/` (Geist + Geist Mono, OFL) and `Icons.xcassets` (Solar, CC BY 4.0) |
///
/// Attribution for the vendored assets and for zeron itself lives in the repository `NOTICE`;
/// see `Resources/Fonts/OFL.txt` and `Resources/Icons.xcassets/ATTRIBUTION.txt`.
public enum SupermuxZeronUI {}
