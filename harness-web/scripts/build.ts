import { build } from "esbuild";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const outDir = resolve(root, "dist");

function escapeForInlineScript(code: string): string {
  return code.replace(/<\/script/gi, "<\\/script").replace(/<!--/g, "<\\!--");
}

const result = await build({
  entryPoints: [resolve(root, "src/main.tsx")],
  bundle: true,
  format: "esm",
  target: "es2022",
  jsx: "automatic",
  minify: true,
  write: false,
  loader: { ".css": "css" },
  outdir: outDir,
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "none",
  logLevel: "info"
});

let js = "";
let css = "";
for (const file of result.outputFiles ?? []) {
  if (file.path.endsWith(".css")) css += file.text;
  else js += file.text;
}

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:; connect-src 'none'; media-src data: blob:">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>Claude</title>
<style>${css.trim()}</style>
</head>
<body>
<div id="root"></div>
<script type="module">${escapeForInlineScript(js.trim())}</script>
</body>
</html>
`;

mkdirSync(outDir, { recursive: true });
writeFileSync(resolve(outDir, "index.html"), html, "utf8");

const bytes = Buffer.byteLength(html, "utf8");
process.stdout.write(
  `dist/index.html — ${(bytes / 1024).toFixed(1)} KB (js ${(js.length / 1024).toFixed(1)} KB, css ${(
    css.length / 1024
  ).toFixed(1)} KB)\n`
);
if (bytes > 2.5 * 1024 * 1024) {
  process.stderr.write("WARNING: bundle exceeds the 2.5 MB budget\n");
  process.exit(1);
}
