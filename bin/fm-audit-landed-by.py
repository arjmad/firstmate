#!/usr/bin/env python3
"""fm-audit-landed-by.py - stamp each audit id a merged PR names into decisions.json.

Usage: fm-audit-landed-by.py [--dry-run] [--table <out.md>] --owner <owner>
         [--owner <owner>...] --since <YYYY-MM-DD> [--until <YYYY-MM-DD>]
         <decisions.json>

Inputs:
  <decisions.json>  the audit's per-id rulings: one JSON object keyed by
                    finding id, each value an object. An entry whose
                    `decision` is present and not `do` (declined, deferred)
                    is never stamped and stays out of the table.
  --owner           a GitHub owner whose repositories hold the fleet's PRs;
                    repeat it for more than one.
  --since, --until  the merge-date window to search, inclusive; --since is
                    the audit's start date, --until defaults to today (UTC).

Source: every PR `gh search prs --merged --owner ... --merged-at
<since>..<until>` returns whose state reads merged. A window that fills
gh's 1000-result cap is split in half until each part fits. A PR names an
id when the id appears in its title or body as a whole token (a1-6 does not
match a1-60, xa1-6 or a1-6-followup). No ledger, backlog row or other prose is read for a
PR URL.

Output: <decisions.json>, rewritten in place.
  - Stamp: an id a merged PR names gets `status` set to `landed` and every
    such PR's URL in `landed_by` (new URLs sorted by repository and number,
    after the URLs already there). An id whose status is `open-helm` or
    `open-captain` gets the URLs but keeps its status, so a PR that lands
    one half of it never marks it done; the helm sets `landed` when the
    live step closes.
  - An existing `landed_by` URL no merged PR in the window names, such as one
    the helm entered by hand, is kept when `gh pr view` reads it MERGED and
    dropped otherwise. A value that is not a PR URL is a refusal.
  - Nothing is un-stamped: an id no PR names keeps its `status`.
  - No other field changes. A new `landed_by` goes last in its object, an
    existing one keeps its place, and the file keeps its indent, ASCII
    escaping and final newline. A run that changes nothing leaves the file
    untouched, so a second run over the same PRs is a no-op.
  --table <out.md> also writes the next audit's prior-status table: one row
    per approved id (Id, Status, Landed by, Title) from the stamped record,
    with a kept hand URL marked `(hand)`.
  One summary line goes to stdout. --dry-run prints it and writes nothing.

Refusals (exit 1, nothing written): a decisions.json that is not an object
of objects, or whose layout this tool cannot reproduce byte for byte (it
never reformats a file), a landed_by that is not a list of PR URLs, a gh
search or view that fails, or a single day that alone fills gh's cap.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile

PR_URL = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$")
FIELD = "landed_by"
# A status naming a step still open outside the PR: a stamp fills landed_by but
# keeps it, so a half-landing never reads as done (firstmate, 2026-11-27).
HELD_STATUSES = frozenset({"open-helm", "open-captain"})
SEARCH_CAP = 1000
USAGE = (
    "usage: fm-audit-landed-by.py [--dry-run] [--table <out.md>] --owner <owner> "
    "[--owner <owner>...] --since <YYYY-MM-DD> [--until <YYYY-MM-DD>] <decisions.json>"
)


class Refusal(RuntimeError):
    pass


class Usage(RuntimeError):
    pass


def gh_json(args: list[str]) -> object:
    try:
        proc = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    except OSError as e:
        raise Refusal(f"gh {args[0]} {args[1]} could not run: {e}") from None
    if proc.returncode != 0:
        raise Refusal(f"gh {' '.join(args[:2])} failed ({proc.returncode}): {proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise Refusal(f"gh {' '.join(args[:2])} printed no JSON: {e}") from None


def search_merged(owners: list[str], since: dt.date, until: dt.date) -> list[dict]:
    """Every merged PR in [since, until], splitting a window that fills the cap."""
    args = ["search", "prs", "--merged"]
    for owner in owners:
        args += ["--owner", owner]
    args += ["--merged-at", f"{since.isoformat()}..{until.isoformat()}",
             "--limit", str(SEARCH_CAP), "--json", "url,title,body,state"]
    found = gh_json(args)
    if not isinstance(found, list):
        raise Refusal("gh search prs did not print a list")
    if len(found) < SEARCH_CAP:
        return found
    if since == until:
        raise Refusal(f"{since}: one day fills gh's {SEARCH_CAP}-result search cap; narrow --owner")
    mid = since + (until - since) // 2
    return search_merged(owners, since, mid) + search_merged(owners, mid + dt.timedelta(days=1), until)


def id_pattern(fid: str) -> re.Pattern[str]:
    return re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(fid) + r"(?![A-Za-z0-9_-])")


def url_key(url: str) -> tuple[str, int]:
    m = PR_URL.match(url)
    return (m.group(1), int(m.group(2))) if m else (url, 0)


def dump_style(raw: str, data: object) -> dict:
    """The json.dumps arguments that reproduce raw exactly, or a refusal."""
    trailing = raw[len(raw.rstrip("\n")):]
    m = re.search(r"\n([ \t]+)\S", raw)
    indents: list[object] = [None] if m is None else [m.group(1) if "\t" in m.group(1) else len(m.group(1))]
    for indent in indents:
        for ensure_ascii in (True, False):
            style = {"indent": indent, "ensure_ascii": ensure_ascii}
            if json.dumps(data, **style) + trailing == raw:
                return {**style, "trailing": trailing}
    raise Refusal("decisions.json is not in a layout this tool can keep byte for byte; refusing to reformat it")


def write_atomic(path: str, text: str, mode: int | None) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".landed-by-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        os.chmod(tmp, mode if mode is not None else 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def table_cell(value: str) -> str:
    return " ".join(value.split()).replace("|", "\\|")


def prior_status_table(data: dict, named: dict[str, list[str]], owners: list[str],
                       since: dt.date, until: dt.date) -> str:
    lines = [
        "# Prior-status table",
        "",
        f"Built by bin/fm-audit-landed-by.py from PRs by {', '.join(owners)} merged "
        f"{since.isoformat()}..{until.isoformat()} that name each id, and from decisions.json's status.",
        "A URL marked (hand) is merged, but no PR this search found names its id with it, as when someone entered it by hand.",
        "",
        "| Id | Status | Landed by | Title |",
        "|---|---|---|---|",
    ]
    for fid, entry in data.items():
        if not approved(entry):
            continue
        urls = [u if u in named.get(fid, []) else f"{u} (hand)" for u in entry.get(FIELD, [])]
        lines.append(
            f"| {table_cell(fid)} | {table_cell(str(entry.get('status') or '-'))} | "
            f"{table_cell(', '.join(urls) or '-')} | {table_cell(str(entry.get('title') or ''))} |"
        )
    return "\n".join(lines) + "\n"


def approved(entry: dict) -> bool:
    return entry.get("decision", "do") == "do"


def parse_args(argv: list[str]) -> dict | None:
    """The options, or None when --help asks for the usage text."""
    opts: dict = {"dry_run": False, "table": None, "owners": [], "since": None, "until": None, "paths": []}
    it = iter(argv)
    for arg in it:
        if arg in ("-h", "--help"):
            return None
        if arg == "--dry-run":
            opts["dry_run"] = True
        elif arg in ("--table", "--owner", "--since", "--until"):
            value = next(it, None)
            if value is None:
                raise Usage(f"{arg} needs a value")
            if arg == "--owner":
                opts["owners"].append(value)
            else:
                opts[arg[2:]] = value
        elif arg.startswith("--"):
            raise Usage(f"unknown option {arg}")
        else:
            opts["paths"].append(arg)
    if len(opts["paths"]) != 1 or not opts["owners"] or not opts["since"]:
        raise Usage("needs one <decisions.json>, at least one --owner and --since")
    for key in ("since", "until"):
        if opts[key] is not None:
            try:
                opts[key] = dt.date.fromisoformat(opts[key])
            except ValueError:
                raise Usage(f"--{key} is not a YYYY-MM-DD date: {opts[key]}") from None
    opts["until"] = opts["until"] or dt.datetime.now(dt.timezone.utc).date()
    if opts["until"] < opts["since"]:
        raise Usage("--until is before --since")
    return opts


def main(argv: list[str]) -> int:
    try:
        opts = parse_args(argv)
    except Usage as e:
        print(f"fm-audit-landed-by: {e}\n{USAGE}", file=sys.stderr)
        return 2
    if opts is None:
        print(__doc__.strip())
        return 0
    decisions_path = opts["paths"][0]
    try:
        with open(decisions_path, encoding="utf-8", newline="") as f:
            raw = f.read()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as e:
            raise Refusal(f"{decisions_path}: not valid JSON: {e}") from None
        if not isinstance(data, dict) or not all(isinstance(v, dict) for v in data.values()):
            raise Refusal(f"{decisions_path}: not an object of per-id objects")
        style = dump_style(raw, data)
        for fid, entry in data.items():
            urls = entry.get(FIELD, [])
            if not isinstance(urls, list) or not all(isinstance(u, str) and PR_URL.match(u) for u in urls):
                raise Refusal(f"{decisions_path}: {fid}'s {FIELD} is not a list of PR URLs")

        merged = [p for p in search_merged(opts["owners"], opts["since"], opts["until"])
                  if isinstance(p, dict) and str(p.get("state", "")).lower() == "merged"
                  and isinstance(p.get("url"), str) and PR_URL.match(p["url"])]
        merged_urls = {p["url"] for p in merged}
        named: dict[str, list[str]] = {}
        for fid, entry in data.items():
            if not approved(entry):
                continue
            rx = id_pattern(fid)
            hits = {p["url"] for p in merged if rx.search(f"{p.get('title') or ''}\n{p.get('body') or ''}")}
            if hits:
                named[fid] = sorted(hits, key=url_key)

        view_cache: dict[str, bool] = {}

        def is_merged(url: str) -> bool:
            if url in merged_urls:
                return True
            if url not in view_cache:
                state = gh_json(["pr", "view", url, "--json", "state"])
                view_cache[url] = isinstance(state, dict) and str(state.get("state", "")).upper() == "MERGED"
            return view_cache[url]

        stamped = newly = held = kept = dropped = 0
        for fid, entry in data.items():
            existing = entry.get(FIELD)
            hits = named.get(fid, [])
            if existing is None and not hits:
                continue
            keep = []
            for url in existing or []:
                if url in hits or is_merged(url):
                    keep.append(url)
                    kept += url not in hits
                else:
                    dropped += 1
            urls = keep + [u for u in hits if u not in keep]
            if existing is not None or urls:
                entry[FIELD] = urls
            if hits:
                stamped += 1
                if entry.get("status") in HELD_STATUSES:
                    held += 1
                elif entry.get("status") != "landed":
                    newly += 1
                    entry["status"] = "landed"

        out = json.dumps(data, indent=style["indent"], ensure_ascii=style["ensure_ascii"]) + style["trailing"]
        changed = out != raw
        verb = "would change" if opts["dry_run"] and changed else "changed" if changed else "unchanged"
        print(
            f"landed_by: {len(merged)} merged PR(s) searched; {stamped} id(s) named by one, "
            f"{newly} newly landed, {held} held at open-helm/open-captain; {kept} hand URL(s) kept, {dropped} unmerged URL(s) dropped; {verb}"
        )
        if not opts["dry_run"]:
            if changed:
                write_atomic(decisions_path, out, os.stat(decisions_path).st_mode & 0o7777)
            if opts["table"]:
                write_atomic(opts["table"], prior_status_table(data, named, opts["owners"], opts["since"], opts["until"]), None)
        return 0
    except (Refusal, OSError, UnicodeDecodeError) as e:
        print(f"fm-audit-landed-by: refused: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
