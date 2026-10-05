import SwiftUI

/// The New Worktree prompt's footer: a thumbnail per attached image (with a
/// remove button), then the attach button on the trailing edge.
struct SupermuxPromptAttachmentStrip: View {
    let attachments: [SupermuxPromptAttachment]
    let canAttach: Bool
    let canEdit: Bool
    let onAttach: () -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            thumbnail(attachment)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Spacer(minLength: 0)
            if canAttach {
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "supermux.newWorktree.attachImages", defaultValue: "Attach Images"))
                .accessibilityLabel(String(localized: "supermux.newWorktree.attachImages", defaultValue: "Attach Images"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 5)
    }

    private func thumbnail(_ attachment: SupermuxPromptAttachment) -> some View {
        SupermuxPromptAttachmentThumbnail(fileURL: attachment.fileURL)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if canEdit {
                    Button { onRemove(attachment.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .help(String(localized: "supermux.newWorktree.removeImage", defaultValue: "Remove Image"))
                    .accessibilityLabel(String(localized: "supermux.newWorktree.removeImage", defaultValue: "Remove Image"))
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 4)
            .help(attachment.name)
    }
}
