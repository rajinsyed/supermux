internal import SupermuxMobileCore

/// Wire DTO -> panel model mappings for a remote Mac's Changes payloads (the
/// reverse of ``SupermuxMobileChangesPayloadBuilder``).
extension SupermuxGitStatusSnapshot {
    /// The snapshot a `changes.status` payload describes. A file whose kind
    /// this build does not know is still listed (as modified), never dropped.
    init(wire dto: SupermuxChangesStatusDTO) {
        guard dto.isRepository == true else {
            self = .notARepository
            return
        }
        self.init(
            isRepository: true,
            branch: dto.branch,
            upstreamBranch: dto.upstreamBranch,
            ahead: dto.ahead ?? 0,
            behind: dto.behind ?? 0,
            staged: (dto.staged ?? []).map(SupermuxGitFileChange.init(wire:)),
            unstaged: (dto.unstaged ?? []).map(SupermuxGitFileChange.init(wire:)),
            untracked: (dto.untracked ?? []).map(SupermuxGitFileChange.init(wire:)),
            stashEntryCount: dto.stashCount ?? 0
        )
    }

    /// A stable text identity of every change (section, kind, paths), empty
    /// when the tree is clean — the remote stand-in for a diff capture.
    var changeFingerprint: String {
        let sections: [(String, [SupermuxGitFileChange])] = [("S", staged), ("U", unstaged), ("N", untracked)]
        return sections.flatMap { label, changes in
            changes.map { "\(label)\t\($0.kind.rawValue)\t\($0.oldPath ?? "")\t\($0.path)" }
        }.joined(separator: "\n")
    }
}

extension SupermuxGitFileChange {
    init(wire dto: SupermuxChangedFileDTO) {
        self.init(path: dto.path, oldPath: dto.oldPath, kind: Kind(rawValue: dto.kind ?? "") ?? .modified)
    }
}

extension SupermuxGitCommit {
    init(wire dto: SupermuxCommitDTO) {
        self.init(
            hash: dto.sha,
            shortHash: dto.shortSha ?? String(dto.sha.prefix(7)),
            author: dto.author ?? "",
            relativeDate: dto.relativeDate ?? "",
            subject: dto.subject ?? ""
        )
    }
}

extension SupermuxGitFileDiff {
    init(wire dto: SupermuxDiffDTO) {
        self.init(isBinary: dto.isBinary ?? false, text: dto.diffText, truncated: dto.truncated ?? false)
    }

    /// The "nothing to show" diff a failed remote read degrades to.
    static let unavailable = SupermuxGitFileDiff(isBinary: false, text: nil, truncated: false)
}
