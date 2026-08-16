import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const source = resolve(root, "src/dev/fixtures/rich-session.jsonl");
const target = resolve(root, "src/dev/fixtures/richSessionRaw.ts");

const raw = readFileSync(source, "utf8");
const body = `export const richSessionRaw = ${JSON.stringify(raw)};\n`;

mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, body, "utf8");
process.stdout.write(`wrote ${target} (${raw.length} bytes)\n`);
