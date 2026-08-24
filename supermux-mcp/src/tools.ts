import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Config } from "./config.ts";
import { readProjects, resolveProject } from "./projects.ts";
import { createWorktree } from "./worktree.ts";
import { socketCall } from "./socket.ts";

function ok(payload: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }],
  };
}

function fail(err: unknown) {
  return {
    content: [{ type: "text" as const, text: (err as Error).message ?? String(err) }],
    isError: true as const,
  };
}

/** Quotes a string for safe interpolation into a POSIX shell command line. */
function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

/** Builds the ccx launch command, validating model/prompt inputs. */
function ccxCommand(ccxBin: string, model?: string, prompt?: string): string {
  const parts = [ccxBin];
  if (model) {
    if (!/^[A-Za-z0-9._\[\]-]+$/.test(model)) throw new Error(`Invalid model name: ${model}`);
    parts.push(model);
  }
  if (prompt) parts.push(shellQuote(prompt));
  return parts.join(" ");
}

export function registerTools(server: McpServer, config: Config): void {
  server.registerTool(
    "list_projects",
    {
      title: "List supermux projects",
      description:
        "List the projects registered in supermux (id, name, root path, worktrees directory).",
      inputSchema: {},
    },
    async () => {
      try {
        const projects = await readProjects(config.projectsFile);
        return ok(
          projects.map((p) => ({
            id: p.id,
            name: p.name,
            rootPath: p.rootPath,
            worktreesDirName: p.worktreesDirName,
          })),
        );
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "create_worktree",
    {
      title: "Create a project worktree",
      description:
        "Create a git worktree in a registered supermux project (same semantics as the app: " +
        "sanitized/deduplicated branch, <root>/.worktrees/<branch>, push.autoSetupRemote). " +
        "Does not open a workspace; use spawn_claude_session with open_workspace for that.",
      inputSchema: {
        project: z.string().describe("Project id or name as registered in supermux"),
        branch: z
          .string()
          .optional()
          .describe("Branch name; blank generates a friendly random name"),
        base_branch: z
          .string()
          .optional()
          .describe("Starting branch (default: project default, then main/master, then HEAD)"),
      },
    },
    async ({ project: projectRef, branch, base_branch }) => {
      try {
        const project = await resolveProject(config.projectsFile, projectRef);
        const worktree = await createWorktree(project, branch, base_branch);
        return ok({ project: project.name, ...worktree, setupCommands: project.setupCommands });
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "spawn_claude_session",
    {
      title: "Spawn a Claude Code (ccx) session",
      description:
        "Create a worktree in a supermux project (unless cwd is given), open a supermux workspace " +
        "there, and start a Claude Code session via the ccx launcher. Runs the project's setup " +
        "commands first when a worktree was created. Returns workspace and worktree identifiers.",
      inputSchema: {
        project: z.string().describe("Project id or name as registered in supermux"),
        branch: z
          .string()
          .optional()
          .describe("Branch for the new worktree; blank generates a name"),
        base_branch: z.string().optional().describe("Starting branch for the worktree"),
        cwd: z
          .string()
          .optional()
          .describe("Skip worktree creation and open the session in this existing directory"),
        model: z
          .string()
          .optional()
          .describe("ccx model alias or id (sol | opus | fable | claude-* | gpt-*)"),
        prompt: z
          .string()
          .optional()
          .describe("Initial prompt passed to the session as an argument"),
        workspace_name: z.string().optional().describe("Title for the supermux workspace"),
        run_setup: z
          .boolean()
          .optional()
          .describe("Run the project's setup commands before ccx (default true for new worktrees)"),
        focus: z.boolean().optional().describe("Focus the new workspace in the app (default false)"),
      },
    },
    async ({ project: projectRef, branch, base_branch, cwd, model, prompt, workspace_name, run_setup, focus }) => {
      try {
        const project = await resolveProject(config.projectsFile, projectRef);

        let directory = cwd;
        let worktree: { branch: string; path: string; base: string } | undefined;
        if (!directory) {
          worktree = await createWorktree(project, branch ?? workspace_name, base_branch);
          directory = worktree.path;
        }

        const shouldRunSetup = (run_setup ?? Boolean(worktree)) && project.setupCommands.length > 0;
        const setupScript = shouldRunSetup
          ? project.setupCommands.map((c) => c.trim()).filter(Boolean).join("\n")
          : "";
        const ccx = ccxCommand(config.ccxBin, model, prompt);
        const initialCommand = setupScript ? `${setupScript}\n${ccx}` : ccx;

        const result = await socketCall(config.socketPath, "workspace.create", {
          cwd: directory,
          title: workspace_name ?? (worktree ? worktree.branch : undefined),
          initial_command: initialCommand,
          focus: focus ?? false,
          workspace_env: {
            SUPERSET_ROOT_PATH: project.rootPath,
            SUPERMUX_ROOT_PATH: project.rootPath,
            SUPERMUX_WORKTREE_PATH: directory,
          },
        });

        return ok({
          project: project.name,
          directory,
          worktree,
          ranSetup: Boolean(setupScript),
          command: ccx,
          workspace: {
            id: result.workspace_id,
            ref: result.workspace_ref,
            window_ref: result.window_ref,
            surface_id: result.surface_id,
          },
        });
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "list_worktrees",
    {
      title: "List project worktrees",
      description: "List git worktrees for a registered supermux project.",
      inputSchema: {
        project: z.string().describe("Project id or name as registered in supermux"),
      },
    },
    async ({ project: projectRef }) => {
      try {
        const project = await resolveProject(config.projectsFile, projectRef);
        const { listWorktrees } = await import("./worktree-list.ts");
        return ok(await listWorktrees(project));
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "list_workspaces",
    {
      title: "List supermux workspaces",
      description: "List open workspaces in the running supermux app.",
      inputSchema: {},
    },
    async () => {
      try {
        const result = await socketCall(config.socketPath, "workspace.list");
        const workspaces = (result.workspaces as Array<Record<string, unknown>> | undefined) ?? [];
        return ok(
          workspaces.map((w) => ({
            ref: w.ref,
            title: w.title,
            directory: w.current_directory,
            description: w.description,
          })),
        );
      } catch (err) {
        return fail(err);
      }
    },
  );
}
