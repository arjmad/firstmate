#!/usr/bin/env node
// fm-lavish-patch.mjs - apply, check, or remove firstmate's local overlay on
// lavish-axi's browser chrome: the fleet-html house dark colours for Lavish's own
// bar, panel, buttons and inputs, a collapsible, drag-resizable desktop
// Conversation panel, and one-line receipts for bearings board answers in that
// panel. The overlay is bin/lavish-patch/chrome.css and
// bin/lavish-patch/chrome-client.js; docs/fork-decisions.md records why it exists
// and which upstream pull requests it tracks.
//
// Usage: fm-lavish-patch.mjs apply|status|remove
//   apply   Make the installed package's dist/chrome.css and dist/chrome-client.js
//           read as upstream's own content followed by this checkout's overlay.
//           Silent when they already do, or when a newer overlay revision is
//           installed. Prints
//           "BOOTSTRAP_INFO: lavish-axi <version> chrome patch applied" after
//           writing. When upstream's files no longer match what the overlay
//           expects, or upstream already ships its own panel collapse, it writes
//           nothing and prints one
//           "LAVISH_PATCH: skipped: lavish-axi <version> <reason>" line: Lavish
//           keeps working unpatched. A read or write failure prints one
//           "LAVISH_PATCH: failed: lavish-axi <version> <reason>" line.
//           Exit 0 when applied, current, newer, absent, or disabled; 3 when
//           skipped; 1 when failed.
//   status  Print one line and exit 0: "absent", "unpatched <version>",
//           "applied <version>", "stale <version>" (an older overlay revision),
//           "newer <version>" (a newer revision than this checkout's), or
//           "incompatible <version>: <reason>".
//   remove  Strip the overlay so both files are upstream's own content again.
//           Prints "removed <version>", "unpatched <version>", or "absent".
//
// The package is the one `lavish-axi` on PATH resolves to through its symlinks,
// <package>/dist/cli.mjs, accepted only when <package>/package.json is named
// lavish-axi; anything else (no lavish-axi, a stub, a wrapper script) is
// "absent" and needs nothing, because firstmate's bootstrap installs Lavish only
// as an npm package in its toolchain prefix. FM_LAVISH_PATCH_PACKAGE=<package
// dir> selects a package directly, for tests and scratch installs.
// FM_LAVISH_PATCH=0 turns apply into a no-op.
//
// The overlay is appended between begin and end marker lines, so stripping it
// restores upstream's bytes exactly. The begin line carries REVISION, and every
// change to bin/lavish-patch/ bumps it: several homes on different firstmate
// commits share one toolchain install, so apply replaces only an older
// revision and leaves a newer one alone rather than downgrading it. Writes are
// staged as same-directory temporary files with each original's mode and
// renamed into place only once every one is written. The Lavish server reads
// both files on every request, so a running board picks the change up on its
// next reload.
//
// Fail closed: before writing, every anchor in ANCHORS must be present in
// upstream's own content. They are what the overlay relies on: the tokens it
// remaps or reads, the desktop panel column, the phone breakpoint, and the
// element ids the script attaches to. UPSTREAM_COLLAPSE names upstream's own
// collapse controls (PR #455's sidebarToggle, PR #429's panelResizer); once one
// ships, the overlay steps aside so the patch can be dropped.

import { chmodSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REVISION = 2;
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
    "--radius-pill:",
    "--w-bold:",
    "--dur-fast:",
    "--ease:",
  ],
  "cli.mjs": [
    'new URL("./chrome.css", import.meta.url)',
    'new URL("./chrome-client.js", import.meta.url)',
    'class="layout"',
    'id="panel"',
    'id="panelScroll"',
    'id="moreWrap"',
    'id="chatLog"',
    'id="queuedLog"',
  ],
};

const UPSTREAM_COLLAPSE = ['id="sidebarToggle"', 'id="panelResizer"'];

class Skip extends Error {}

function readPackage(dir) {
  try {
    const manifest = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
    return manifest.name === "lavish-axi" ? { dir, version: String(manifest.version || "unknown") } : null;
  } catch {
    return null;
  }
}

function findPackage() {
  const explicit = process.env.FM_LAVISH_PATCH_PACKAGE;
  if (explicit) return readPackage(explicit);
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    if (!dir) continue;
    let target;
    try {
      target = realpathSync(join(dir, "lavish-axi"));
    } catch {
      continue;
    }
    const pkg = dirname(dirname(target));
    return target === join(pkg, "dist", "cli.mjs") ? readPackage(pkg) : null;
  }
  return null;
}

function markerLine(target, word) {
  return target.open + word + target.close;
}

// Upstream's own content, with any overlay revision stripped from its begin
// line to the end of the file, and that revision's number (0 for one written
// before revisions were numbered). The newline before the marker is the overlay's.
function split(target, content) {
  const at = content.indexOf("\n" + target.open + BEGIN);
  if (at === -1) return { pristine: content, revision: null };
  const line = content.slice(at + 1, content.indexOf("\n", at + 1));
  const match = line.match(/ r(\d+)\b/);
  return { pristine: content.slice(0, at), revision: match ? Number(match[1]) : 0 };
}

function overlayBlock(target) {
  let body;
  try {
    body = readFileSync(join(OVERLAY_DIR, target.file), "utf8");
  } catch (error) {
    throw new Error(`cannot read overlay bin/lavish-patch/${target.file}: ${error.code || error.message}`);
  }
  if (!body.endsWith("\n")) body += "\n";
  return "\n" + markerLine(target, `${BEGIN} r${REVISION}`) + "\n" + body + markerLine(target, END) + "\n";
}

// Every target with its current and wanted content. Throws Skip when upstream
// no longer matches the overlay, and Error when a file cannot be read.
function inspect(pkg) {
  const dist = join(pkg.dir, "dist");
  const files = TARGETS.map((target) => {
    const path = join(dist, target.file);
    let content;
    try {
      content = readFileSync(path, "utf8");
    } catch {
      throw new Skip(`has no dist/${target.file}`);
    }
    const { pristine, revision } = split(target, content);
    return { path, content, pristine, revision, wanted: pristine + overlayBlock(target) };
  });
  let cli;
  try {
    cli = readFileSync(join(dist, "cli.mjs"), "utf8");
  } catch {
    throw new Skip("has no dist/cli.mjs");
  }
  const sources = { "chrome.css": files[0].pristine, "cli.mjs": cli };
  for (const [file, anchors] of Object.entries(ANCHORS)) {
    const missing = anchors.find((anchor) => !sources[file].includes(anchor));
    if (missing) throw new Skip(`dist/${file} no longer contains ${JSON.stringify(missing)} the overlay relies on`);
  }
  const own = UPSTREAM_COLLAPSE.find((marker) => cli.includes(marker));
  if (own) throw new Skip(`ships its own conversation-panel collapse (${own}); drop this patch`);
  return files;
}

const newer = (files) => files.some((f) => f.revision !== null && f.revision > REVISION);

// Stage every new content beside its file first, then rename them all into
// place, so a failed write changes nothing.
function writeAll(changes) {
  const staged = [];
  try {
    for (const { path, content } of changes) {
      const mode = statSync(path).mode & 0o7777;
      const tmp = join(dirname(path), `.${process.pid}.${staged.length}.fm-lavish-patch.tmp`);
      staged.push({ tmp, path });
      writeFileSync(tmp, content, { mode });
      chmodSync(tmp, mode);
    }
  } catch (error) {
    for (const { tmp } of staged) {
      try {
        unlinkSync(tmp);
      } catch {
        // Never written.
      }
    }
    throw new Error(`could not write ${error.path || "dist"}: ${error.code || error.message}`);
  }
  for (const { tmp, path } of staged) renameSync(tmp, path);
}

function apply(pkg) {
  const files = inspect(pkg);
  if (newer(files)) return null;
  const stale = files.filter((f) => f.content !== f.wanted);
  if (stale.length === 0) return null;
  writeAll(stale.map((f) => ({ path: f.path, content: f.wanted })));
  return `BOOTSTRAP_INFO: lavish-axi ${pkg.version} chrome patch applied`;
}

function status(pkg) {
  let files;
  try {
    files = inspect(pkg);
  } catch (error) {
    if (error instanceof Skip) return `incompatible ${pkg.version}: ${error.message}`;
    throw error;
  }
  if (newer(files)) return `newer ${pkg.version}`;
  if (files.every((f) => f.content === f.wanted)) return `applied ${pkg.version}`;
  if (files.some((f) => f.revision !== null)) return `stale ${pkg.version}`;
  return `unpatched ${pkg.version}`;
}

function remove(pkg) {
  const changes = [];
  for (const target of TARGETS) {
    const path = join(pkg.dir, "dist", target.file);
    let content;
    try {
      content = readFileSync(path, "utf8");
    } catch {
      continue;
    }
    const { pristine, revision } = split(target, content);
    if (revision !== null) changes.push({ path, content: pristine });
  }
  if (changes.length === 0) return `unpatched ${pkg.version}`;
  writeAll(changes);
  return `removed ${pkg.version}`;
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
try {
  const line = { apply, status, remove }[command](pkg);
  if (line) console.log(line);
} catch (error) {
  if (error instanceof Skip) {
    console.log(`LAVISH_PATCH: skipped: lavish-axi ${pkg.version} ${error.message}`);
    process.exit(3);
  }
  console.log(`LAVISH_PATCH: failed: lavish-axi ${pkg.version} ${error.message}`);
  process.exit(1);
}
