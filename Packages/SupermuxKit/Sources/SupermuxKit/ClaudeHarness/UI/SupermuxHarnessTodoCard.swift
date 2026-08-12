import SwiftUI
import CmuxFoundation

/// The plan a `TodoWrite` call wrote, with a segmented progress ring.
///
/// One arc per step (not a continuous ring): a five-step plan at 3/5 reads as
/// "three of five done" at a glance, which a smooth arc does not convey.
struct SupermuxHarnessTodoCard: View {
    let todos: [SupermuxHarnessTodo]
    let theme: SupermuxHarnessTheme

    var body: some View {
        HStack(alignment: .top, spacing: SupermuxHarnessTokens.spacing10) {
            SupermuxHarnessTodoRing(
                total: todos.count,
                completed: completedCount,
                inProgress: inProgressCount,
                theme: theme
            )
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
                Text(progressLabel)
                    .cmuxFont(size: SupermuxHarnessTokens.caption, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(theme.mutedText)
                ForEach(todos) { todo in
                    SupermuxHarnessTodoRow(todo: todo, theme: theme)
                }
            }
        }
        .padding(SupermuxHarnessTokens.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.cardRadius, style: .continuous
            )
            .fill(theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.cardRadius, style: .continuous
            )
            .strokeBorder(theme.border, lineWidth: SupermuxHarnessTokens.hairline)
        )
    }

    private var completedCount: Int {
        todos.reduce(0) { $0 + ($1.state == .completed ? 1 : 0) }
    }

    private var inProgressCount: Int {
        todos.reduce(0) { $0 + ($1.state == .inProgress ? 1 : 0) }
    }

    private var progressLabel: String {
        String(
            format: String(
                localized: "supermux.harness.todo.progress",
                defaultValue: "%lld of %lld done"
            ),
            Int64(completedCount),
            Int64(todos.count)
        )
    }
}

/// One plan step.
struct SupermuxHarnessTodoRow: View {
    let todo: SupermuxHarnessTodo
    let theme: SupermuxHarnessTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SupermuxHarnessTokens.spacing6) {
            Image(systemName: symbol)
                .font(.system(size: SupermuxHarnessTokens.caption))
                .foregroundStyle(color)
            Text(todo.content)
                .cmuxFont(size: SupermuxHarnessTokens.footnote)
                .foregroundStyle(todo.state == .completed ? theme.mutedText : theme.text)
                .strikethrough(todo.state == .completed, color: theme.mutedText)
        }
    }

    private var symbol: String {
        switch todo.state {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch todo.state {
        case .pending: return theme.mutedText
        case .inProgress: return theme.toolAccent
        case .completed: return theme.accent
        }
    }
}

/// The segmented completion ring.
struct SupermuxHarnessTodoRing: View {
    let total: Int
    let completed: Int
    let inProgress: Int
    let theme: SupermuxHarnessTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(2, diameter * 0.14)
            ZStack {
                ForEach(0..<max(total, 1), id: \.self) { index in
                    segment(
                        index: index,
                        count: max(total, 1),
                        diameter: diameter,
                        lineWidth: lineWidth
                    )
                    .stroke(
                        color(for: index),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                }
            }
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(-90))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.25),
                value: completed * 1000 + inProgress
            )
        }
        .accessibilityLabel(
            String(
                localized: "supermux.harness.todo.ringAccessibility",
                defaultValue: "Plan progress"
            )
        )
        .accessibilityValue("\(completed)/\(max(total, 1))")
    }

    /// One arc per step, with a gap wide enough that segments stay countable.
    /// remodex uses trim fractions `min(0.05, 0.4/count)`, i.e. 18° for a
    /// 5-step plan; the earlier 6° cap read as a continuous ring.
    private func segment(
        index: Int, count: Int, diameter: CGFloat, lineWidth: CGFloat
    ) -> Path {
        let sweep = 360.0 / Double(count)
        let gap = min(18.0, 144.0 / Double(count))
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        return Path { path in
            path.addArc(
                center: center,
                radius: max(diameter / 2 - lineWidth / 2, 1),
                startAngle: .degrees(Double(index) * sweep + gap / 2),
                endAngle: .degrees(Double(index + 1) * sweep - gap / 2),
                clockwise: false
            )
        }
    }

    /// One tint at three strengths (remodex): completed full, in-progress
    /// partial, pending faint. Two hues in a 28pt ring read as noise and lose
    /// the "fills as it advances" progression.
    private func color(for index: Int) -> Color {
        if index < completed { return theme.accent }
        if index < completed + inProgress { return theme.accent.opacity(0.45) }
        return theme.accent.opacity(0.16)
    }
}
