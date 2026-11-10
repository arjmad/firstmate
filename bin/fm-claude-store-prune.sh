#!/usr/bin/env bash
# fm-claude-store-prune.sh - remove Claude Code project entries that point at
# paths that no longer exist from the per-user Claude store,
# <CLAUDE_CONFIG_DIR or HOME>/.claude.json. Such an entry holds a workspace
# trust record for a folder that is gone (a retired task worktree, a removed
# secondmate home, a test's temporary directory), so it holds no unique data.
#
# Usage: fm-claude-store-prune.sh [--dry-run] --missing
#        fm-claude-store-prune.sh --path <dir>
#        --missing
#          Every `projects` entry whose path does not exist. A real run first
#          writes a dated backup of the whole store beside it,
#          .claude.json.fm-prune-backup-<YYYYMMDDTHHMMSSZ>, then replaces the
#          store atomically. Run it once by hand to clear what accumulated
#          before teardown removed its own entries.
#        --dry-run
#          With --missing: list what a real run would remove and change
#          nothing, no backup included.
#        --path <dir>
#          The one entry keyed exactly <dir>, and only when <dir> does not
#          exist. bin/fm-teardown.sh runs this for the launch directory of a
#          Claude task it retired; no backup is written for one entry.
#
# The store is the one CLAUDE_CONFIG_DIR selects (an absolute path), else
# $HOME's. A symlinked store keeps its link: the bytes go to its target.
#
# What is removed. Only keys of the store's top-level `projects` object, and
# only a key that is an absolute path whose lstat fails with "no such file or
# directory"; a path that exists, a dangling symlink, a path this user cannot
# inspect, and a key that is not an absolute path all stay. Every other part of
# the store stays byte for byte as JSON, rewritten with two-space indentation
# as Claude Code itself writes it.
#
# How it writes. Under Claude Code's own store lock
# (bin/fm-claude-store-lock.mjs owns that protocol): read, decide, stage the new
# store beside its target, recheck that the store did not change since it was
# read (retrying up to three times when it did), and rename the staged file
# over it. The result is read back, and the run fails unless exactly the
# decided entries are gone and every other entry is still there.
#
# Output:
#   would remove: <path>          (--dry-run, one per entry)
#   removed: <path>               (one per entry)
#   claude store: removed|would remove <n> of <m> project entries from <store>[; backup <file>]
# A run with nothing to remove prints only that summary line under --missing,
# and nothing under --path. A missing store is nothing to remove. A refusal is
# an `error:` on stderr and exits 1; an unusable argument exits 2.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

MODE=
DRY_RUN=0
TARGET=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --missing) [ -z "$MODE" ] || { echo "error: choose --missing or --path once" >&2; exit 2; }; MODE=missing ;;
    --path)
      [ -z "$MODE" ] || { echo "error: choose --missing or --path once" >&2; exit 2; }
      [ $# -ge 2 ] || { echo "error: --path needs a directory" >&2; exit 2; }
      MODE=path
      TARGET=$2
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "error: usage: fm-claude-store-prune.sh [--dry-run] --missing | --path <dir>" >&2; exit 2; }
if [ "$MODE" = path ]; then
  [ "$DRY_RUN" -eq 0 ] || { echo "error: --dry-run goes with --missing" >&2; exit 2; }
  case "$TARGET" in /?*) ;; *) echo "error: --path takes an absolute path" >&2; exit 2 ;; esac
fi

case "${CLAUDE_CONFIG_DIR:-}" in
  ''|/*) ;;
  *) echo "error: CLAUDE_CONFIG_DIR '$CLAUDE_CONFIG_DIR' is a relative path" >&2; exit 1 ;;
esac
CONFIG_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-}}
[ -n "$CONFIG_DIR" ] || { echo "error: neither CLAUDE_CONFIG_DIR nor HOME is set" >&2; exit 1; }
STORE="$CONFIG_DIR/.claude.json"
[ -e "$STORE" ] || [ -L "$STORE" ] || {
  [ "$MODE" = path ] || printf 'claude store: %s 0 of 0 project entries from %s\n' \
    "$([ "$DRY_RUN" -eq 1 ] && echo "would remove" || echo removed)" "$STORE"
  exit 0
}
command -v node >/dev/null 2>&1 || { echo "error: node is required to rewrite $STORE" >&2; exit 1; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
node --input-type=module - "$SCRIPT_DIR/fm-claude-store-lock.mjs" "$STORE" "$MODE" "$DRY_RUN" "$STAMP" "$TARGET" <<'NODE'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { pathToFileURL } from "node:url";
const [lib, link, mode, dryRun, stamp, target] = process.argv.slice(2);
const { withClaudeStoreLock, StoreLockRefused } = await import(pathToFileURL(lib).href);
// A refusal throws, so one raised inside the store lock still unwinds through
// the lock's own release before the process exits.
class Refused extends Error {}
const fail = (msg) => { throw new Refused(msg); };
process.on("uncaughtException", (err) => {
  console.error(err instanceof Refused ? `error: ${err.message}` : err);
  process.exit(1);
});
let store;
try { store = fs.realpathSync(link); } catch { fail(`${link} is a symlink whose target cannot be resolved`); }
const stat = fs.statSync(store);
if (!stat.isFile() || stat.uid !== process.getuid()) fail(`${store} is not a regular file this user owns`);

// Gone only on ENOENT: anything uncertain keeps its entry (header).
const gone = (key) => {
  if (!path.isAbsolute(key)) return false;
  try { fs.lstatSync(key); return false; } catch (err) { return err.code === "ENOENT"; }
};
const parse = (buf) => {
  const root = JSON.parse(buf.toString("utf8"));
  if (root === null || typeof root !== "object" || Array.isArray(root)) fail(`${store} is not a JSON object`);
  const projects = root.projects;
  if (projects === undefined) return [root, {}];
  if (projects === null || typeof projects !== "object" || Array.isArray(projects)) {
    fail(`${store} has a non-object "projects" value`);
  }
  return [root, projects];
};
const decide = (projects) => Object.keys(projects).filter((k) => (mode === "path" ? k === target : true) && gone(k));
const summary = (verb, n, total, extra = "") => {
  if (mode === "path" && n === 0) return;
  console.log(`claude store: ${verb} ${n} of ${total} project entries from ${store}${extra}`);
};
const wantBackup = mode === "missing";
const fingerprint = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

if (dryRun === "1") {
  const [, projects] = parse(fs.readFileSync(store));
  const removed = decide(projects);
  for (const key of removed) console.log(`would remove: ${key}`);
  summary("would remove", removed.length, Object.keys(projects).length);
  process.exit(0);
}

const rewrite = (replaceStore) => {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const original = fs.readFileSync(store);
    const [root, projects] = parse(original);
    const total = Object.keys(projects).length;
    const removed = decide(projects);
    if (removed.length === 0) return { removed, total, backup: null };
    const kept = Object.keys(projects).filter((k) => !removed.includes(k));
    for (const key of removed) delete projects[key];
    const fileMode = fs.statSync(store).mode & 0o777;
    const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
    let backup = null;
    if (wantBackup) {
      backup = path.join(path.dirname(store), `${path.basename(store)}.fm-prune-backup-${stamp}`);
      if (fs.existsSync(backup)) backup = `${backup}.${unique}`;
      fs.writeFileSync(backup, original, { mode: fileMode, flag: "wx" });
    }
    const tmp = path.join(path.dirname(store), `.claude.json.fm-store-prune.${unique}`);
    fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: fileMode, flag: "wx" });
    let renamed = false;
    try {
      if (fingerprint(fs.readFileSync(store)) !== fingerprint(original)) {
        if (backup !== null) fs.rmSync(backup, { force: true });
        continue;
      }
      replaceStore(tmp);
      renamed = true;
    } finally {
      if (!renamed) fs.rmSync(tmp, { force: true });
    }
    const back = Object.keys(parse(fs.readFileSync(store))[1]);
    if (back.some((k) => removed.includes(k)) || kept.some((k) => !back.includes(k))) {
      fail(`${store} did not keep exactly the entries whose paths exist${backup ? `; the backup is ${backup}` : ""}`);
    }
    return { removed, total, backup };
  }
  fail(`${store} kept changing while its dead project entries were being removed; it is unchanged`);
};
let result;
try {
  result = withClaudeStoreLock({ storeLink: link, writeTarget: store, doing: "dead project entries were being removed" }, rewrite);
} catch (err) {
  if (!(err instanceof StoreLockRefused)) throw err;
  fail(err.message);
}
for (const key of result.removed) console.log(`removed: ${key}`);
summary("removed", result.removed.length, result.total, result.backup ? `; backup ${result.backup}` : "");
NODE
