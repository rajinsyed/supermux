import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { loadConfig } from "./config.ts";
import { registerTools } from "./tools.ts";

const config = loadConfig();

function authorized(req: IncomingMessage): boolean {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) return false;
  const presented = Buffer.from(header.slice("Bearer ".length));
  const expected = Buffer.from(config.token);
  return presented.length === expected.length && timingSafeEqual(presented, expected);
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const raw = Buffer.concat(chunks).toString("utf8");
  return raw ? JSON.parse(raw) : undefined;
}

// Stateless mode: a fresh McpServer + transport per request. No sessions to
// track, nothing to clean up, and horizontal restarts are free — the right
// trade for a small local control server.
async function handleMcp(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const server = new McpServer({ name: "supermux", version: "0.1.0" });
  registerTools(server, config);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    transport.close();
    server.close();
  });
  await server.connect(transport);
  await transport.handleRequest(req, res, await readBody(req));
}

const httpServer = createServer(async (req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  if (!req.url?.startsWith("/mcp")) {
    res.writeHead(404).end();
    return;
  }
  if (!authorized(req)) {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "Missing or invalid bearer token" }));
    return;
  }
  try {
    await handleMcp(req, res);
  } catch (err) {
    console.error("MCP request failed:", err);
    if (!res.headersSent) {
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "Internal server error" }));
    }
  }
});

httpServer.listen(config.port, config.host, () => {
  console.log(`supermux-mcp listening on http://${config.host}:${config.port}/mcp`);
  console.log(`  control socket : ${config.socketPath}`);
  console.log(`  projects file  : ${config.projectsFile}`);
  console.log(`  ccx binary     : ${config.ccxBin}`);
  if (config.tokenGenerated) {
    console.log(`  bearer token   : ${config.token}`);
    console.log("  (set SUPERMUX_MCP_TOKEN to pin a stable token)");
  }
});
