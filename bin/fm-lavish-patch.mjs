#!/usr/bin/env node
// fm-lavish-patch.mjs - apply, check, or remove firstmate's local overlay on
// lavish-axi's browser chrome: the fleet-html house dark colours for Lavish's own
// bar, panel, buttons and inputs, and a collapsible, drag-resizable desktop
// Conversation panel. The overlay is bin/lavish-patch/chrome.css and
// bin/lavish-patch/chrome-client.js; docs/fork-decisions.md records why it exists
// and which upstream pull requests it tracks.
//
// Usage: fm-lavish-patch.mjs apply|status|remove
//   apply   Make the installed package's dist/chrome.css and dist/chrome-client.js
//           read as upstream's own content followed by the current overlay.
//           Silent when they already do. Prints
//           "BOOTSTRAP_INFO: lavish-axi <version> chrome patch applied" after
//           writing. When upstream's files no longer match what the overlay
//           expects, or upstream already ships its own panel collapse, it writes
//           nothing and prints one
//           "LAVISH_PATCH: skipped: lavish-axi <version> <reason>" line: Lavish
//           keeps working unpatched. A write failure prints
//           "LAVISH_PATCH: failed: lavish-axi <version> <reason>".
//           Exit 0 when applied, current, absent, or disabled; 3 when skipped;
//           1 when failed.
//   status  Print one line and exit 0: "absent", "unpatched <version>",
//           "applied <version>", "stale <version>" (an older overlay revision),
//           or "incompatible <version>: <reason>".
//   remove  Strip the overlay so both files are upstream's own content again.
//           Prints "removed <version>", "unpatched <version>", or "absent".
//
// The package is the one `lavish-axi` on PATH resolves to through its symlinks,
// <package>/dist/cli.mjs, accepted only when <package>/package.json is named
// lavish-axi; anything else (no lavish-axi, a stub, a non-npm build) is "absent"
// and needs nothing. FM_LAVISH_PATCH_PACKAGE=<package dir> selects a package
// directly, for tests and scratch installs. FM_LAVISH_PATCH=0 turns apply into a
// no-op.
//
// The overlay is appended between begin and end marker lines, so stripping it
// restores upstream's bytes exactly, and applying again over an older revision
// replaces it. Each write is a same-directory temporary file renamed into place
// with the original file's mode; the Lavish server reads both files on every
// request, so a running board picks the change up on its next reload.
//
// Fail closed: before writing, every anchor in ANCHORS must be present in
// upstream's own content. They are what the overlay relies on: the token names
// it remaps, the desktop panel column, the phone breakpoint, and the element ids
// the script attaches to. UPSTREAM_COLLAPSE names upstream's own collapse
// controls (PR #455's sidebarToggle, PR #429's panelResizer); once one ships,
// the overlay steps aside so the patch can be dropped.

import { chmodSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const OVERLAY_DIR = join(HERE, "lavish-patch");
const BEGIN = "fm-lavish-patch:begin";
const END = "fm-lavish-patch:end";

const TARGETS = [
  { file: "chrome.css", open: "/* ", close: " */" },
  { file: "chrome-client.js", open: "// ", close: "" },
];

const ANCHORS = {
  "chrome.css": [
    "--panel-w:",
    "grid-template-columns: minmax(0, 1fr) var(--panel-w);",
    "@media (max-width: 860px)",
    "--bg-panel:",
    "--bg-bar:",
    "--border-strong:",
    "--accent-ink:",
  ],
  "cli.mjs": [
    'new URL("./chrome.css", import.meta.url)',
    'new URL("./chrome-client.js", import.meta.url)',
    'class="layout"',
    'id="panel"',
    'id="moreWrap"',
    'id="chatLog"',
    'id="queuedLog"',
  ],
};

const UPSTREAM_COLLAPSE = ['id="sidebarToggle"', 'id="panelResizer"'];

function findPackage() {
  const explicit = process.env.FM_LAVISH_PATCH_PACKAGE;
  if (explicit) return isLavishPackage(explicit) ? explicit : null;
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    if (!dir) continue;
    let target;
    try {
      target = realpathSync(join(dir, "lavish-axi"));
    } catch {
      continue;
    }
    const pkg = dirname(dirname(target));
    return target === join(pkg, "dist", "cli.mjs") && isLavishPackage(pkg) ? pkg : null;
  }
  return null;
}

function isLavishPackage(pkg) {
  try {
    return JSON.parse(readFileSync(join(pkg, "package.json"), "utf8")).name === "lavish-axi";
  } catch {
    return false;
  }
}

function version(pkg) {
  try {
    return String(JSON.parse(readFileSync(join(pkg, "package.json"), "utf8")).version || "unknown");
  } catch {
    return "unknown";
  }
}

function markerLine(target, word) {
  return target.open + word + target.close;
}

// Upstream's own content, with any overlay revision stripped from its marker
// line to the end of the file. The newline before the marker is the overlay's.
function split(target, content) {
  const begin = "\n" + markerLine(target, BEGIN) + "\n";
  const at = content.indexOf(begin);
  return at === -1 ? { pristine: content, patched: false } : { pristine: content.slice(0, at), patched: true };
}

function overlayBlock(target) {
  let body = readFileSync(join(OVERLAY_DIR, target.file), "utf8");
  if (!body.endsWith("\n")) body += "\n";
  return "\n" + markerLine(target, BEGIN) + "\n" + body + markerLine(target, END) + "\n";
}

function inspect(pkg) {
  const dist = join(pkg, "dist");
  const files = [];
  for (const target of TARGETS) {
    const path = join(dist, target.file);
    let content;
    try {
      content = readFileSync(path, "utf8");
    } catch {
      return { reason: `has no dist/${target.file}` };
    }
    const { pristine, patched } = split(target, content);
    files.push({ target, path, content, pristine, patched, wanted: pristine + overlayBlock(target) });
  }
  let cli;
  try {
    cli = readFileSync(join(dist, "cli.mjs"), "utf8");
  } catch {
    return { reason: "has no dist/cli.mjs" };
  }
  const sources = { "chrome.css": files[0].pristine, "cli.mjs": cli };
  for (const [file, anchors] of Object.entries(ANCHORS)) {
    const missing = anchors.find((anchor) => !sources[file].includes(anchor));
    if (missing) return { reason: `dist/${file} no longer contains ${JSON.stringify(missing)} the overlay relies on` };
  }
  const own = UPSTREAM_COLLAPSE.find((marker) => cli.includes(marker));
  if (own) return { reason: `ships its own conversation-panel collapse (${own}); drop this patch` };
  return { files };
}

function writeInPlace(path, content) {
  const mode = statSync(path).mode & 0o7777;
  const tmp = join(dirname(path), `.${process.pid}.fm-lavish-patch.tmp`);
  try {
    writeFileSync(tmp, content, { mode });
    chmodSync(tmp, mode);
    renameSync(tmp, path);
  } catch (error) {
    try {
      unlinkSync(tmp);
    } catch {
      // Nothing was left behind.
    }
    throw error;
  }
}

function apply(pkg) {
  const v = version(pkg);
  const found = inspect(pkg);
  if (found.reason) {
    console.log(`LAVISH_PATCH: skipped: lavish-axi ${v} ${found.reason}`);
    return 3;
  }
  const stale = found.files.filter((f) => f.content !== f.wanted);
  if (stale.length === 0) return 0;
  try {
    for (const f of stale) writeInPlace(f.path, f.wanted);
  } catch (error) {
    console.log(`LAVISH_PATCH: failed: lavish-axi ${v} could not write ${error.path || "dist"}: ${error.code || error.message}`);
    return 1;
  }
  console.log(`BOOTSTRAP_INFO: lavish-axi ${v} chrome patch applied`);
  return 0;
}

function status(pkg) {
  const v = version(pkg);
  const found = inspect(pkg);
  if (found.reason) return `incompatible ${v}: ${found.reason}`;
  if (found.files.every((f) => f.content === f.wanted)) return `applied ${v}`;
  if (found.files.some((f) => f.patched)) return `stale ${v}`;
  return `unpatched ${v}`;
}

function remove(pkg) {
  const v = version(pkg);
  let removed = false;
  for (const target of TARGETS) {
    const path = join(pkg, "dist", target.file);
    let content;
    try {
      content = readFileSync(path, "utf8");
    } catch {
      continue;
    }
    const { pristine, patched } = split(target, content);
    if (!patched) continue;
    writeInPlace(path, pristine);
    removed = true;
  }
  return removed ? `removed ${v}` : `unpatched ${v}`;
}

const command = process.argv[2];
if (!["apply", "status", "remove"].includes(command) || process.argv.length > 3) {
  console.error("usage: fm-lavish-patch.mjs apply|status|remove");
  process.exit(2);
}
if (command === "apply" && process.env.FM_LAVISH_PATCH === "0") process.exit(0);
const pkg = findPackage();
if (!pkg) {
  if (command !== "apply") console.log("absent");
  process.exit(0);
}
if (command === "apply") process.exit(apply(pkg));
try {
  console.log(command === "status" ? status(pkg) : remove(pkg));
} catch (error) {
  console.log(`LAVISH_PATCH: failed: lavish-axi ${version(pkg)} could not write ${error.path || "dist"}: ${error.code || error.message}`);
  process.exit(1);
}
