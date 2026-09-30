import SwiftUI

/// The New Worktree sheet's "Create on" row: one chip per Mac that has the
/// project (This Mac first, each with a link-state dot), unreachable Macs
/// listed but disabled, and a "Set Up on…" menu for connected Macs that lack
/// the project. A short line underneath says where a remote create happens.
struct SupermuxNewWorktreeDevicePicker: View {
    let sheet: SupermuxNewWorktreeSheetModel

    private var createEntries: [SupermuxWorktreeDeviceEntry] { sheet.entries.filter { $0.location != nil } }
    private var setUpEntries: [SupermuxWorktreeDeviceEntry] { sheet.entries.filter { $0.setUpDestination != nil } }
    private var isBusy: Bool { sheet.phase != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "supermux.newWorktree.device.label", defaultValue: "Create on"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(createEntries) { entry in
                            chip(entry)
                        }
                        if !setUpEntries.isEmpty {
                            setUpMenu
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            // The line is always laid out (blank for This Mac), so switching
            // Macs never makes the sheet jump.
            Text(verbatim: hint ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(hint == nil ? 0 : 1)
                .accessibilityHidden(hint == nil)
        }
    }

    private func chip(_ entry: SupermuxWorktreeDeviceEntry) -> some View {
        let isSelected = entry.id == sheet.selectedEntryID
        return Button {
            sheet.selectEntry(id: entry.id)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor(entry.availability))
                    .frame(width: 6, height: 6)
                // One weight for both states, so selecting never resizes the chip.
                Text(entry.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let status = statusText(entry.availability) {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(
                isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                lineWidth: 1
            ))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || (!entry.canCreate && !isSelected))
        .opacity(entry.canCreate || isSelected ? 1 : 0.55)
        .help(help(for: entry))
        .accessibilityLabel(String(
            localized: "supermux.newWorktree.device.accessibility",
            defaultValue: "Create on \(entry.name)"
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var setUpMenu: some View {
        Menu {
            ForEach(setUpEntries) { entry in
                Button(String(localized: "supermux.project.setUpOn", defaultValue: "Set Up on \(entry.name)…")) {
                    sheet.selectEntry(id: entry.id)
                }
                .disabled(entry.availability != .online)
            }
        } label: {
            SupermuxAgentChipLabel(
                systemImage: "plus",
                text: String(localized: "supermux.newWorktree.device.setUp", defaultValue: "Set Up on…")
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(String(
            localized: "supermux.newWorktree.device.setUpHelp",
            defaultValue: "Register this project on another Mac first."
        ))
    }

    /// Where the worktree goes, or why the selected Mac cannot take it.
    private var hint: String? {
        guard let entry = sheet.selectedEntry, !entry.isThisMac else { return nil }
        return unavailableReason(entry) ?? String(
            localized: "supermux.newWorktree.device.remoteHint",
            defaultValue: "Creates the worktree on \(entry.name) and opens it here."
        )
    }

    private func help(for entry: SupermuxWorktreeDeviceEntry) -> String {
        unavailableReason(entry) ?? String(
            localized: "supermux.newWorktree.device.accessibility",
            defaultValue: "Create on \(entry.name)"
        )
    }

    /// Why a Mac cannot take a worktree right now; `nil` when it can.
    private func unavailableReason(_ entry: SupermuxWorktreeDeviceEntry) -> String? {
        switch entry.availability {
        case .online:
            return nil
        case .connecting:
            return String(
                localized: "supermux.newWorktree.device.connectingHint",
                defaultValue: "\(entry.name) is still connecting. Try again in a moment."
            )
        case .offline:
            return String(
                localized: "supermux.newWorktree.device.offlineHint",
                defaultValue: "\(entry.name) is offline. Worktrees can be created there once it reconnects."
            )
        }
    }

    private func statusText(_ availability: SupermuxWorktreeDeviceAvailability) -> String? {
        switch availability {
        case .online: return nil
        case .connecting:
            return String(localized: "supermux.newWorktree.device.connecting", defaultValue: "Connecting…")
        case .offline:
            return String(localized: "supermux.newWorktree.device.offline", defaultValue: "Offline")
        }
    }

    private func dotColor(_ availability: SupermuxWorktreeDeviceAvailability) -> Color {
        switch availability {
        case .online: return .green
        case .connecting: return .orange
        case .offline: return Color.secondary.opacity(0.6)
        }
    }
}
