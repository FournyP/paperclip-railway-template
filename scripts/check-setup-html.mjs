// Syntax-checks the setup page the browser actually receives.
//
// The setup UI lives in a template literal returned by setupHtml() in
// src/server.js. That means an escape sequence in the inline <script> is
// consumed twice: once when the template literal is evaluated, once by the
// browser. `node --check src/server.js` only proves the server file parses --
// it says nothing about the emitted HTML, so a nested quote in a JS string can
// pass every server-side check and still throw a SyntaxError in the browser,
// which aborts the whole inline script and freezes the page at "checking...".
//
// Run from the repo root: node scripts/check-setup-html.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const src = fs.readFileSync("src/server.js", "utf8");
const start = src.indexOf("function setupHtml() {");
if (start < 0) throw new Error("setupHtml() not found in src/server.js");
const open = src.indexOf("`", start);
const close = src.indexOf("`;", open + 1);
if (open < 0 || close < 0) throw new Error("could not delimit setupHtml()'s template literal");

const html = new Function(`return ${src.slice(open, close + 1)};`)();
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
if (scripts.length === 0) throw new Error("no inline <script> found in the rendered setup page");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "setup-html-"));
try {
  scripts.forEach((body, i) => {
    const file = path.join(tmp, `inline-${i}.js`);
    fs.writeFileSync(file, body);
    execFileSync(process.execPath, ["--check", file], { stdio: "pipe" });
    console.log(`inline script ${i}: syntax ok (${body.length} bytes)`);
  });
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
