import { readFile } from "node:fs/promises";

/** The subset of a supermux project record this server needs. */
export interface Project {
  id: string;
  name: string;
  rootPath: string;
  worktreesDirName: string;
  defaultBranch?: string;
  setupCommands: string[];
}

interface ProjectsDocument {
  projects?: Array<Record<string, unknown>>;
}

/**
 * Reads registered projects from supermux-projects.json (read-only — the app
 * owns writes; this server never mutates the document).
 */
export async function readProjects(file: string): Promise<Project[]> {
  let raw: string;
  try {
    raw = await readFile(file, "utf8");
  } catch (err) {
    throw new Error(`Cannot read supermux projects file at ${file}: ${(err as Error).message}`);
  }
  const doc = JSON.parse(raw) as ProjectsDocument;
  return (doc.projects ?? []).flatMap((p) => {
    if (typeof p.id !== "string" || typeof p.name !== "string" || typeof p.rootPath !== "string") {
      return [];
    }
    return [
      {
        id: p.id,
        name: p.name,
        rootPath: p.rootPath,
        worktreesDirName: typeof p.worktreesDirName === "string" && p.worktreesDirName ? p.worktreesDirName : ".worktrees",
        defaultBranch: typeof p.defaultBranch === "string" && p.defaultBranch ? p.defaultBranch : undefined,
        setupCommands: Array.isArray(p.setupCommands) ? p.setupCommands.filter((c): c is string => typeof c === "string") : [],
      },
    ];
  });
}

/** Resolves a project by exact id, then case-insensitive unique name match. */
export async function resolveProject(file: string, ref: string): Promise<Project> {
  const projects = await readProjects(file);
  const byId = projects.find((p) => p.id === ref);
  if (byId) return byId;
  const needle = ref.trim().toLowerCase();
  const byName = projects.filter((p) => p.name.toLowerCase() === needle);
  if (byName.length === 1) return byName[0]!;
  if (byName.length > 1) {
    throw new Error(`Project name "${ref}" is ambiguous; use the project id. Candidates: ${byName.map((p) => p.id).join(", ")}`);
  }
  const known = projects.map((p) => `${p.name} (${p.id})`).join(", ") || "none registered";
  throw new Error(`Unknown project "${ref}". Known projects: ${known}`);
}
