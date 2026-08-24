import { spawn } from "node:child_process";
import { join } from "node:path";
import type { Project } from "./projects.ts";

export interface WorktreeEntry {
  path: string;
  branch: string | null;
  isSupermuxManaged: boolean;
}

/** Lists a project's worktrees via `git worktree list --porcelain`. */
export function listWorktrees(project: Project): Promise<WorktreeEntry[]> {
  return new Promise((resolve, reject) => {
    const child = spawn("git", ["worktree", "list", "--porcelain"], {
      cwd: project.rootPath,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("close", (status) => {
      if (status !== 0) {
        reject(new Error(`git worktree list failed: ${stderr.trim()}`));
        return;
      }
      const managedPrefix = join(project.rootPath, project.worktreesDirName) + "/";
      const entries: WorktreeEntry[] = [];
      let path: string | undefined;
      let branch: string | null = null;
      const flush = () => {
        if (path && path !== project.rootPath) {
          entries.push({ path, branch, isSupermuxManaged: path.startsWith(managedPrefix) });
        }
        path = undefined;
        branch = null;
      };
      for (const line of stdout.split("\n")) {
        if (line.startsWith("worktree ")) {
          flush();
          path = line.slice("worktree ".length);
        } else if (line.startsWith("branch refs/heads/")) {
          branch = line.slice("branch refs/heads/".length);
        } else if (line === "") {
          flush();
        }
      }
      flush();
      resolve(entries);
    });
  });
}
