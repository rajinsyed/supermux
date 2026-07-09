import SupermuxMobileKit
import SwiftUI

/// The push/pull result sheet: the operation as its title, the Mac's raw git
/// `log_lines` in a monospaced scroll, a subtle truncation note when the Mac
/// capped the log, and a placeholder when git printed nothing.
struct SupermuxSyncLogSheet: View {
    let entry: SupermuxChangesSyncLogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text(String(
                                localized: "supermux.common.done",
                                defaultValue: "Done",
                                bundle: .module
                            ))
                        }
                        .accessibilityIdentifier("SupermuxSyncLogDoneButton")
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch entry.operation {
        case .push:
            String(localized: "supermux.changes.action.push", defaultValue: "Push", bundle: .module)
        case .pull:
            String(localized: "supermux.changes.action.pull", defaultValue: "Pull", bundle: .module)
        }
    }

    @ViewBuilder
    private var content: some View {
        if entry.lines.isEmpty {
            Text(String(
                localized: "supermux.changes.sync.noOutput",
                defaultValue: "No output.",
                bundle: .module
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 3) {
                    // Raw git output: verbatim, line-keyed by position (git
                    // progress lines legitimately repeat).
                    ForEach(Array(entry.lines.enumerated()), id: \.offset) { line in
                        Text(verbatim: line.element)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if entry.truncated {
                        Text(String(
                            localized: "supermux.changes.sync.truncated",
                            defaultValue: "Output truncated.",
                            bundle: .module
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .accessibilityIdentifier("SupermuxSyncLogTruncatedNote")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("SupermuxSyncLogSheet")
        }
    }
}
