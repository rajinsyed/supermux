import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

/** Runtime configuration, resolved once at startup from the environment. */
export interface Config {
  /** TCP host to bind. Loopback by default; set SUPERMUX_MCP_HOST to expose. */
  host: string;
  /** TCP port for the Streamable HTTP endpoint. */
  port: number;
  /** Bearer token required on every request. Generated when not provided. */
  token: string;
  /** Whether the token was generated this run (so we print it once). */
  tokenGenerated: boolean;
  /** Path to the supermux control socket. */
  socketPath: string;
  /** Path to supermux-projects.json. */
  projectsFile: string;
  /** Executable used to launch Claude Code sessions. */
  ccxBin: string;
}

export function loadConfig(env: Record<string, string | undefined> = process.env): Config {
  const explicitToken = env.SUPERMUX_MCP_TOKEN?.trim();
  const token = explicitToken || randomBytes(24).toString("base64url");
  return {
    host: env.SUPERMUX_MCP_HOST || "127.0.0.1",
    port: Number(env.SUPERMUX_MCP_PORT) || 8787,
    token,
    tokenGenerated: !explicitToken,
    socketPath: env.SUPERMUX_SOCKET_PATH || "/tmp/supermux.sock",
    projectsFile:
      env.SUPERMUX_PROJECTS_FILE ||
      join(homedir(), "Library/Application Support/cmux/supermux-projects.json"),
    ccxBin: env.SUPERMUX_MCP_CCX_BIN || "ccx",
  };
}
