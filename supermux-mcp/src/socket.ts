import { createConnection } from "node:net";
import { randomUUID } from "node:crypto";

/**
 * The app's default `cmuxOnly` access mode admits a peer only when it is a
 * live descendant of the app process, or when each command is wrapped in a
 * capability envelope: `_cmux_capability_v1 <token> <command>`. The token is
 * the `CMUX_SOCKET_CAPABILITY` value the app exports into terminals it spawns
 * (HMAC-signed, valid across restarts for release builds). A server daemonized
 * outside the app MUST present it — a backgrounded process gets reparented to
 * launchd and silently loses descendant status.
 */
const capabilityToken = (process.env.SUPERMUX_MCP_CAPABILITY || process.env.CMUX_SOCKET_CAPABILITY || "").trim();

function frame(line: string): string {
  return capabilityToken ? `_cmux_capability_v1 ${capabilityToken} ${line}\n` : `${line}\n`;
}

/**
 * Minimal client for the supermux app's v2 control socket: one newline-framed
 * JSON request, one newline-framed JSON response per connection.
 */
export async function socketCall(
  socketPath: string,
  method: string,
  params: Record<string, unknown> = {},
  timeoutMs = 15_000,
): Promise<Record<string, unknown>> {
  const request = frame(JSON.stringify({ id: randomUUID(), method, params }));
  const raw = await new Promise<string>((resolve, reject) => {
    const conn = createConnection(socketPath);
    let buffer = "";
    let settled = false;
    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      conn.destroy();
      fn();
    };
    const timer = setTimeout(
      () => finish(() => reject(new Error(`supermux socket timed out after ${timeoutMs}ms (${method})`))),
      timeoutMs,
    );
    conn.on("connect", () => conn.write(request));
    conn.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline >= 0) finish(() => resolve(buffer.slice(0, newline)));
    });
    conn.on("error", (err) =>
      finish(() => reject(new Error(`supermux socket unavailable at ${socketPath}: ${err.message}. Is the Supermux app running?`))),
    );
    conn.on("close", () => finish(() => reject(new Error("supermux socket closed before responding"))));
  });

  // The server may emit plain-text errors before the JSON protocol engages.
  if (raw.startsWith("ERROR:")) throw new Error(raw);
  const response = JSON.parse(raw) as {
    ok?: boolean;
    result?: Record<string, unknown>;
    error?: { code?: string; message?: string };
  };
  if (response.ok) return response.result ?? {};
  const code = response.error?.code ?? "error";
  const message = response.error?.message ?? "Unknown supermux socket error";
  throw new Error(`supermux ${method} failed (${code}): ${message}`);
}
