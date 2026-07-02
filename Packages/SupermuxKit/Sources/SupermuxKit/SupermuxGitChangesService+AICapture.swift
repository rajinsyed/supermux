import Foundation

/// The non-mutating change captures behind the AI "Generate & Commit" flow.
///
/// Split out of `SupermuxGitChangesService.swift` to keep the service file
/// inside the fork's Swift file-length budget.
extension SupermuxGitChangesService {
    /// Byte cap for the AI-commit patch capture. The messenger only ever feeds
    /// the model ~12,000 characters, so 64 KiB leaves ample headroom (even for
    /// multibyte text) while keeping a lockfile-churn diff from ballooning into
    /// hundreds of megabytes of pipe traffic and String copies.
    static let maxAIPatchBytes = 65536

    /// A non-mutating diff of everything a "stage all + commit" would capture,
    /// for AI commit-message generation.
    ///
    /// Combines `git diff HEAD --stat` + a byte-capped `git diff HEAD
    /// --unified=1` patch (all tracked changes vs the last commit, staged or
    /// not; see ``maxAIPatchBytes``) with a list of untracked files. It does
    /// **not** touch the index, so the caller can generate a message first and
    /// only stage when a message is in hand (keeping the operation atomic).
    /// Returns an empty string when there is nothing to commit or the path is
    /// not a repository. On an unborn branch `git diff HEAD` fails and only the
    /// untracked listing is returned.
    ///
    /// Untracked files appear by NAME only — their content identity is
    /// ``untrackedContentDigest(repoPath:)``, which the AI flow's staleness
    /// guard compares alongside this diff.
    /// - Parameter repoPath: Repository directory.
    public func uncommittedDiff(repoPath: String) async -> String {
        // The three legs are independent read-only captures; run them
        // concurrently (the actor is free while each awaits its subprocess,
        // and every invocation carries --no-optional-locks).
        async let statLeg = runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [Self.noOptionalLocks, "diff", "HEAD", "--stat"],
            timeout: Self.gitTimeout
        )
        async let patchLeg = boundedPatch(repoPath: repoPath)
        async let untrackedLeg = runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [Self.noOptionalLocks, "ls-files", "--others", "--exclude-standard"],
            timeout: Self.gitTimeout
        )
        let (stat, patch, untracked) = await (statLeg, patchLeg, untrackedLeg)
        var parts: [String] = []
        if let summary = stat.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append(summary)
        }
        if let body = patch?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            parts.append(body)
        }
        if let files = untracked.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !files.isEmpty {
            parts.append("New untracked files:\n" + files)
        }
        return parts.joined(separator: "\n\n")
    }

    /// An opaque identity token for the *content* of every untracked file a
    /// `git add -A` would sweep in, for the AI flow's staleness guard.
    ///
    /// ``uncommittedDiff(repoPath:)`` lists untracked files by name only, so
    /// an untracked file whose bytes change during the multi-second AI call
    /// would slip past a diff comparison and be committed under a message
    /// that never described them. Identity is `name + size + permissions +
    /// inode + full-precision ctime + mtime` from one `ls-files -z | xargs -0
    /// stat` pipeline: no content reads, so a multi-gigabyte untracked
    /// artifact cannot stall the commit the way hashing would. Every real
    /// mid-flight change is caught: editors bump mtime on save (APFS is
    /// nanosecond-granular, `%Fm`/`%Fc` print the fraction), replace-style
    /// writes change the inode, and even an mtime-preserving in-place rewrite
    /// (`touch -r`, `rsync -t`) bumps ctime — which nothing user-space can
    /// suppress. The bytes are base64-armored so a non-UTF-8 filename cannot
    /// nil the runner's strict stdout decode into a false-empty token.
    /// Callers compare the token only for equality. Empty when there are no
    /// untracked files (macOS `xargs` skips the command on empty input).
    ///
    /// The `--` terminator keeps a dash-prefixed filename (`-config`) from
    /// being parsed as `stat` options, which would fail the entire xargs
    /// batch and empty the digest. With `pipefail`, a file vanishing
    /// mid-pipeline (or any other leg failure) yields the
    /// `"untracked-digest-unavailable"` sentinel for that capture instead of
    /// a silently truncated token. The sentinel is deliberately STABLE, not
    /// per-capture-varying: two failed captures compare equal, so a
    /// deterministic failure costs at most one safe regeneration rather than
    /// aborting every AI commit.
    /// - Parameter repoPath: Repository directory.
    public func untrackedContentDigest(repoPath: String) async -> String {
        let script = "set -o pipefail;"
            + " git \(Self.noOptionalLocks) ls-files --others --exclude-standard -z"
            + " | /usr/bin/xargs -0 /usr/bin/stat -f '%N %z %p %i %Fc %Fm' -- 2>/dev/null"
            + " | /usr/bin/base64"
        let result = await runShellPipeline(script, in: repoPath, shell: "/bin/bash")
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0,
              let stdout = result.stdout
        else { return "untracked-digest-unavailable" }
        return stdout
    }

    /// A stable identity for the FULL tracked diff, closing the staleness
    /// guard's blind spot past ``maxAIPatchBytes``: the model-facing patch
    /// from ``uncommittedDiff(repoPath:)`` stays capped at 64 KiB, so an edit
    /// whose diff section lies beyond the cap changes neither that patch nor
    /// the `--stat` summary — only this digest sees it. Callers compare the
    /// digest for equality only.
    ///
    /// `shasum` output is ASCII hex, so it always survives the runner's
    /// strict UTF-8 stdout decode. On an unborn branch `git diff HEAD` fails
    /// and `shasum` hashes empty input into a constant digest — harmless,
    /// since the untracked digest covers that tree. On any pipeline failure
    /// the STABLE `"tracked-digest-unavailable"` sentinel is returned (same
    /// rationale as ``untrackedContentDigest(repoPath:)``: a deterministic
    /// failure must not abort every AI commit).
    /// - Parameter repoPath: Repository directory.
    public func trackedDiffDigest(repoPath: String) async -> String {
        let script = "git \(Self.noOptionalLocks) diff HEAD --binary --unified=0"
            + " | /usr/bin/shasum -a 256"
        let result = await runShellPipeline(script, in: repoPath)
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0,
              let stdout = result.stdout
        else { return "tracked-digest-unavailable" }
        return stdout
    }

    /// The tracked-changes patch for the AI flow, bounded at the source rather
    /// than after a full in-memory capture: `head -c` stops reading at
    /// ``maxAIPatchBytes`` (git then exits early on SIGPIPE, so a huge diff
    /// returns fast instead of timing out) and `iconv -c` drops a multibyte
    /// character the byte cap may have split, keeping the output valid UTF-8.
    /// `--unified=1` trims context lines the model does not need. Run through
    /// `/usr/bin/env` with an explicit `PATH` for the same reason as
    /// ``fetch(repoPath:)``: the shell resolves `git`, `head`, and `iconv`
    /// itself, bypassing ``CommandRunner``'s executable resolution.
    ///
    /// The pipeline's exit status is deliberately ignored (mirroring the
    /// previous plain `git diff HEAD` capture): macOS `iconv` exits non-zero
    /// after repairing a cap-split character even though it wrote the whole
    /// valid prefix, and a failing `git diff` (unborn branch) simply yields an
    /// empty patch, which the caller already skips.
    private func boundedPatch(repoPath: String) async -> String? {
        let script = "git \(Self.noOptionalLocks) diff HEAD --unified=1"
            + " | head -c \(Self.maxAIPatchBytes) | iconv -c -f utf-8 -t utf-8"
        return await runShellPipeline(script, in: repoPath).stdout
    }
}
