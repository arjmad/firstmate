// The one owner of Claude Code's store lock for every firstmate write to its
// per-user store, <CLAUDE_CONFIG_DIR or HOME>/.claude.json. Imported by the
// inline node programs of bin/fm-claude-trust.sh and bin/fm-live-lab.sh
// forget-claude; it has no command-line entry point.
//
// Claude Code serialises its own writes to the store through a lock directory
// next to it, <store>.lock, made with mkdir and treated as stale once its mtime
// is 10 seconds old (proper-lockfile, read from the 2.1.318 bundle). It keys
// that lock on the store path it was given, so a symlinked store is locked
// beside the link and never beside its target; callers pass that unresolved
// path as storeLink and write the bytes to the resolved writeTarget, which
// keeps the link in place.
//
// A caller holds the lock for the milliseconds its read, rewrite, and rename
// take, and a Claude save that finds it held waits and then re-reads. Claude
// writes without the lock only after about 14 seconds of retries, far past that
// hold, so a caller's fingerprint recheck is the guard left for that case and
// for any writer that does not take the lock. A stale lock is broken only if
// the directory moved aside is still the one judged stale; a fresh one held
// past the wait fails closed with the store untouched. The rename also needs
// the lock still ours and under half the stale age, so a stalled run gives up
// rather than write after Claude could have broken its lock; what remains is
// the instant between that check and the rename.
// tests/fm-claude-store-lock-live-e2e.test.sh proves the vendor side.

import fs from "node:fs";
import crypto from "node:crypto";

const STALE_MS = 10000;
const WAIT_MS = 15000;

// A refusal that leaves the store unchanged. Its message names the lock or the
// store and carries no "error:" prefix; each caller prints it its own way.
export class StoreLockRefused extends Error {}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const sameLock = (a, b) => a !== null && b !== null && a.ino === b.ino && a.mtimeMs === b.mtimeMs;

// Run fn(replaceStore) while holding <storeLink>.lock and return its value.
// replaceStore(stagedFile) renames stagedFile over writeTarget only while the
// lock is still ours and young enough that Claude cannot yet judge it stale;
// otherwise it throws StoreLockRefused naming what was being done. The lock is
// released, only if still ours, however fn ends, and fn's own errors propagate.
export function withClaudeStoreLock({ storeLink, writeTarget, doing }, fn) {
  const lockDir = `${storeLink}.lock`;
  const lockStat = () => {
    try { return fs.statSync(lockDir); } catch (err) { if (err.code === "ENOENT") return null; throw err; }
  };
  // A stale lock is broken by renaming it aside and checking that the directory
  // moved is the one judged stale. If a fresh lock replaced it in between, the
  // run stops without writing, so that holder's write is never overwritten.
  const breakStale = (held) => {
    if (!held.isDirectory()) {
      throw new StoreLockRefused(`${lockDir} is not a lock directory; remove it by hand; ${writeTarget} is unchanged`);
    }
    const grave = `${lockDir}.fm-store-lock-stale.${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
    try { fs.renameSync(lockDir, grave); } catch (err) { if (err.code === "ENOENT") return; throw err; }
    if (sameLock(fs.statSync(grave), held)) {
      try { fs.rmdirSync(grave); } catch { /* an unexpected non-empty lock stays aside */ }
      return;
    }
    // A fresh lock replaced the stale one before the rename: put it back unless a
    // newer one already took the name, and stop without writing.
    if (lockStat() === null) {
      try { fs.renameSync(grave, lockDir); } catch { /* left aside; its holder keeps writing */ }
    }
    throw new StoreLockRefused(`a fresh ${lockDir} replaced the stale one while it was being broken; ${writeTarget} is unchanged`);
  };
  const acquire = () => {
    const deadline = Date.now() + WAIT_MS;
    for (let delay = 50; ; delay = Math.min(delay * 2, 1000)) {
      if (Date.now() >= deadline) {
        throw new StoreLockRefused(`${lockDir} stayed held by another writer for ${WAIT_MS / 1000}s; ${writeTarget} is unchanged`);
      }
      let made = false;
      try { fs.mkdirSync(lockDir); made = true; } catch (err) { if (err.code !== "EEXIST") throw err; }
      const held = lockStat();
      if (made && held !== null) return { lock: held, at: Date.now() };
      if (!made && held === null) continue;
      if (!made && Date.now() - held.mtimeMs > STALE_MS) { breakStale(held); continue; }
      sleep(delay);
    }
  };
  const mine = acquire();
  const replaceStore = (stagedFile) => {
    if (!sameLock(lockStat(), mine.lock) || Date.now() - mine.at >= STALE_MS / 2) {
      throw new StoreLockRefused(`${lockDir} was taken over or went stale while ${doing}; ${writeTarget} is unchanged`);
    }
    fs.renameSync(stagedFile, writeTarget);
  };
  try {
    return fn(replaceStore);
  } finally {
    if (sameLock(lockStat(), mine.lock)) fs.rmdirSync(lockDir);
  }
}
