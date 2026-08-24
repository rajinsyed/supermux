import { spawn } from "node:child_process";
import { appendFile, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import type { Project } from "./projects.ts";

const GIT_TIMEOUT_MS = 30_000;
const CHECKOUT_TIMEOUT_MS = 120_000;

interface GitResult {
  status: number;
  stdout: string;
  stderr: string;
}

function runGit(cwd: string, args: string[], timeoutMs = GIT_TIMEOUT_MS): Promise<GitResult> {
  return new Promise((resolve, reject) => {
    const child = spawn("git", args, {
      cwd,
      env: { ...process.env, LC_ALL: "C" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`git ${args.join(" ")} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (status) => {
      clearTimeout(timer);
      resolve({ status: status ?? 1, stdout, stderr });
    });
  });
}

/**
 * Sanitizes free-form input into a git-safe branch name, mirroring
 * SupermuxBranchName.sanitize (spaces → dashes, strip invalid chars, collapse
 * separators, per-component ref rules, 100-char cap; "HEAD" → null).
 */
export function sanitizeBranch(raw: string): string | null {
  let name = raw.trim().replaceAll(" ", "-");
  name = name.replace(/[^A-Za-z0-9._/-]/g, "");
  while (name.includes("--")) name = name.replaceAll("--", "-");
  while (name.includes("..")) name = name.replaceAll("..", ".");
  while (name.includes("//")) name = name.replaceAll("//", "/");
  name = name.replace(/^[-./]+|[-./]+$/g, "");
  name = name
    .split("/")
    .map((component) => {
      let c = component;
      let changed = true;
      while (changed) {
        changed = false;
        while (c.startsWith(".")) {
          c = c.slice(1);
          changed = true;
        }
        while (c.endsWith(".lock")) {
          c = c.slice(0, -".lock".length);
          changed = true;
        }
      }
      return c;
    })
    .filter(Boolean)
    .join("/");
  if (name.length > 100) {
    name = name.slice(0, 100).replace(/^[-./]+|[-./]+$/g, "");
  }
  if (!name || name === "HEAD") return null;
  return name;
}

const PREDICATES = ["calm", "brisk", "cheerful", "quiet", "bright", "swift", "gentle", "bold", "keen", "merry"];
const OBJECTS = ["river", "meadow", "harbor", "summit", "grove", "canyon", "lagoon", "prairie", "glacier", "orchard"];

function randomName(): string {
  const pick = (list: string[]) => list[Math.floor(Math.random() * list.length)]!;
  return `${pick(PREDICATES)}-${pick(OBJECTS)}`;
}

/** Branch name → single worktree directory component (slashes become dashes). */
export function directoryComponent(branch: string): string {
  return branch.replaceAll("/", "-");
}

async function localBranches(root: string): Promise<string[]> {
  const result = await runGit(root, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]);
  if (result.status !== 0) throw new Error(`git for-each-ref failed: ${result.stderr.trim()}`);
  return result.stdout.split("\n").map((l) => l.trim()).filter(Boolean);
}

async function refExists(root: string, ref: string): Promise<boolean> {
  const result = await runGit(root, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
  return result.status === 0;
}

async function resolveBase(root: string, requested: string | undefined): Promise<string> {
  if (requested) {
    if (await refExists(root, requested)) return requested;
    if (await refExists(root, `origin/${requested}`)) return `origin/${requested}`;
    throw new Error(`Base branch "${requested}" not found (locally or on origin)`);
  }
  for (const candidate of ["main", "master"]) {
    if (await refExists(root, candidate)) return candidate;
  }
  return "HEAD";
}

function dedupe(candidate: string, taken: Set<string>, takenDirs: Set<string>): string {
  const free = (name: string) =>
    !taken.has(name.toLowerCase()) && !takenDirs.has(directoryComponent(name).toLowerCase());
  if (free(candidate)) return candidate;
  for (let n = 2; n < 10_000; n++) {
    const attempt = `${candidate}-${n}`;
    if (free(attempt)) return attempt;
  }
  return `${candidate}-${Date.now().toString(36)}`;
}

/**
 * Best-effort: adds `/<worktreesDirName>/` to `.git/info/exclude` so worktrees
 * never show as untracked in the main checkout (mirrors the app's
 * ensureWorktreesDirIgnored). Failures are swallowed — exclusion is cosmetic.
 */
async function ensureWorktreesDirIgnored(project: Project): Promise<void> {
  try {
    const result = await runGit(project.rootPath, ["rev-parse", "--git-common-dir"]);
    if (result.status !== 0) return;
    let gitDir = result.stdout.trim();
    if (!gitDir) return;
    if (!gitDir.startsWith("/")) gitDir = join(project.rootPath, gitDir);
    const infoDir = join(gitDir, "info");
    const excludePath = join(infoDir, "exclude");
    const pattern = `/${project.worktreesDirName}/`;
    const existing = await readFile(excludePath, "utf8").catch(() => "");
    if (existing.split("\n").includes(pattern)) return;
    await mkdir(infoDir, { recursive: true });
    const prefix = existing && !existing.endsWith("\n") ? "\n" : "";
    await appendFile(excludePath, `${prefix}${pattern}\n`);
  } catch {
    // best-effort
  }
}

export interface CreatedWorktree {
  branch: string;
  path: string;
  base: string;
}

/**
 * Creates a project worktree with piggycode/supermux semantics:
 * `<root>/<worktreesDirName>/<branch-as-dir>`, `git worktree add --no-track -b`,
 * `push.autoSetupRemote=true`, `branch.<name>.base` recorded, branch/dir
 * deduplicated against existing ones.
 */
export async function createWorktree(
  project: Project,
  requestedBranch: string | undefined,
  baseBranch: string | undefined,
): Promise<CreatedWorktree> {
  const check = await runGit(project.rootPath, ["rev-parse", "--is-inside-work-tree"]);
  if (check.status !== 0) throw new Error(`${project.rootPath} is not a git repository`);

  const sanitized = (requestedBranch && sanitizeBranch(requestedBranch)) || randomName();
  const base = await resolveBase(project.rootPath, baseBranch?.trim() || project.defaultBranch);

  const worktreesDir = join(project.rootPath, project.worktreesDirName);
  if (!worktreesDir.startsWith(project.rootPath + "/")) {
    throw new Error(`Unsafe worktrees directory: ${worktreesDir}`);
  }
  await mkdir(worktreesDir, { recursive: true });
  await ensureWorktreesDirIgnored(project);

  const existing = await localBranches(project.rootPath);
  const listed = await runGit(project.rootPath, ["worktree", "list", "--porcelain"]);
  const takenDirs = new Set(
    listed.stdout
      .split("\n")
      .filter((l) => l.startsWith("worktree "))
      .map((l) => l.slice("worktree ".length).split("/").pop()!.toLowerCase()),
  );
  const branch = dedupe(sanitized, new Set(existing.map((b) => b.toLowerCase())), takenDirs);
  const worktreePath = join(worktreesDir, directoryComponent(branch));

  const add = await runGit(
    project.rootPath,
    ["worktree", "add", "--no-track", "-b", branch, worktreePath, base],
    CHECKOUT_TIMEOUT_MS,
  );
  if (add.status !== 0) {
    throw new Error(`git worktree add failed: ${(add.stderr || add.stdout).trim()}`);
  }

  // Best-effort config, matching the app (failures never roll back the add).
  await runGit(worktreePath, ["config", "--local", "push.autoSetupRemote", "true"]).catch(() => {});
  await runGit(worktreePath, ["config", `branch.${branch}.base`, base]).catch(() => {});

  return { branch, path: worktreePath, base };
}
