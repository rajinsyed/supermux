import Foundation
import SupermuxKit

extension SupermuxWorkspaceSwitcherController {
    /// Builds the frozen, value-typed cards for one hold session.
    ///
    /// Every open workspace in `order` becomes a card — including project-owned
    /// workspaces, which live in `TabManager.tabs` even though the sidebar hides
    /// them. Each card is enriched with its owning project's color/icon/name when
    /// the workspace resolves to a registered project (explicit association or a
    /// worktree directory), so "all workspaces (projects and normal)" are
    /// represented uniformly.
    func buildItems(order: [UUID], manager: TabManager) -> [SupermuxWorkspaceSwitcherItem] {
        let currentId = manager.selectedTabId
        let projects = SupermuxComposition.projectsModel.projects
        let workspacesById = Dictionary(
            manager.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        return order.compactMap { id in
            guard let workspace = workspacesById[id] else { return nil }

            let resolvedProjectId: UUID? = projects.isEmpty ? nil : SupermuxComposition.workspaceAssociations.projectId(
                forWorkspace: workspace.id,
                directory: workspace.currentDirectory,
                in: projects
            )
            let project = resolvedProjectId.flatMap { pid in projects.first(where: { $0.id == pid }) }

            let directoryName = (workspace.currentDirectory as NSString).lastPathComponent
            let rawTitle = workspace.customTitle ?? workspace.title
            let title = rawTitle.isEmpty ? directoryName : rawTitle
            let branch = workspace.supermuxSidebarBranch
            let subtitle = branch ?? (directoryName.isEmpty ? nil : directoryName)

            return SupermuxWorkspaceSwitcherItem(
                id: workspace.id,
                title: title,
                subtitle: subtitle,
                accentColorHex: workspace.customColor ?? project?.colorHex,
                iconSymbol: project?.iconSymbol,
                monogram: SupermuxWorkspaceSwitcherItem.monogram(for: title),
                projectId: resolvedProjectId,
                projectName: project?.name,
                isCurrent: id == currentId
            )
        }
    }
}
