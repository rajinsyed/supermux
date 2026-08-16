import { build, type BuildOptions } from "esbuild";
import { readFileSync, watch } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const PORT = Number(process.env.PORT ?? 5199);

const options: BuildOptions = {
  entryPoints: [resolve(root, "src/dev/main.tsx")],
  bundle: true,
  format: "esm",
  target: "es2022",
  jsx: "automatic",
  sourcemap: "inline",
  write: false,
  loader: { ".css": "css" },
  outdir: resolve(root, ".devout"),
  define: { "process.env.NODE_ENV": '"development"' },
  logLevel: "warning"
};

async function bundle(): Promise<{ js: string; css: string }> {
  const result = await build(options);
  let js = "";
  let css = "";
  for (const file of result.outputFiles ?? []) {
    if (file.path.endsWith(".css")) css += file.text;
    else js += file.text;
  }
  return { js, css };
}

let cache: { js: string; css: string } | undefined;
let building: Promise<{ js: string; css: string }> | undefined;

async function current(): Promise<{ js: string; css: string }> {
  if (cache) return cache;
  if (!building) {
    building = bundle().then((result) => {
      cache = result;
      building = undefined;
      return result;
    });
  }
  return building;
}

const html = readFileSync(resolve(root, "dev/standalone.html"), "utf8");

watch(resolve(root, "src"), { recursive: true }, () => {
  cache = undefined;
});

const server = Bun.serve({
  port: PORT,
  hostname: "127.0.0.1",
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/reload") {
      cache = undefined;
      return new Response("ok");
    }
    try {
      const built = await current();
      if (url.pathname === "/app.js") {
        return new Response(built.js, {
          headers: { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-store" }
        });
      }
      if (url.pathname === "/app.css") {
        return new Response(built.css, {
          headers: { "content-type": "text/css; charset=utf-8", "cache-control": "no-store" }
        });
      }
      return new Response(html, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return new Response(`<pre style="padding:20px;font:12px monospace">${message}</pre>`, {
        status: 500,
        headers: { "content-type": "text/html; charset=utf-8" }
      });
    }
  }
});

process.stdout.write(`harness-web dev server → http://127.0.0.1:${server.port}/?scenario=rich&theme=dark\n`);
