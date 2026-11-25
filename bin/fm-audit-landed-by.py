#!/usr/bin/env python3
"""fm-audit-landed-by.py - write each landed audit id's PR URLs into decisions.json.

Usage: fm-audit-landed-by.py [--dry-run] <ledger.md> <decisions.json>

Inputs:
  <ledger.md>       an audit wrap-up ledger: a Markdown table whose header row
                    names at least the columns `Id`, `Status` and
                    `Where it landed / evidence`, one row per approved id.
  <decisions.json>  the audit's per-id rulings: one JSON object keyed by
                    finding id, each value an object.

Output:
  <decisions.json>, rewritten in place. Each id whose ledger Status is
  `landed` gets `landed_by`: every https://github.com/<owner>/<repo>/pull/<n>
  in its evidence cell, in cell order without repeats. A landed id with no PR
  URL gets an empty list (landed without a PR, such as a helm step or a
  setting). An id the ledger lists with any other status loses a `landed_by`
  an earlier run wrote; an id the ledger does not list is left alone. No other
  field changes. A new `landed_by` goes last in its object, an existing one
  keeps its place, and the file keeps its indent, ASCII escaping and final
  newline. A run that changes nothing leaves the file untouched, so a second
  run is a no-op. One summary line goes to stdout. --dry-run prints the summary
  and writes nothing.

Refusals (exit 1, file untouched): no recognizable ledger table, a ledger row
with a duplicate id or a missing column, a ledger id decisions.json does not
hold, a decisions.json that is not an object of objects, or one whose layout
this tool cannot reproduce byte for byte (it never reformats a file).
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile

PR_URL = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+(?![0-9])")
SEPARATOR_CELL = re.compile(r"^:?-+:?$")
ID_COL, STATUS_COL, WHERE_COL = "Id", "Status", "Where it landed / evidence"
FIELD = "landed_by"


class Refusal(RuntimeError):
    pass


def cells(line: str) -> list[str] | None:
    line = line.strip()
    if not (line.startswith("|") and line.endswith("|") and len(line) > 1):
        return None
    return [c.strip() for c in line[1:-1].split("|")]


def read_ledger(path: str) -> dict[str, tuple[str, str]]:
    """Map each ledger id to (status, evidence cell)."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines[:-1]):
        header = cells(line)
        sep = cells(lines[i + 1])
        if not header or not sep or len(sep) != len(header):
            continue
        if not all(SEPARATOR_CELL.match(c) for c in sep):
            continue
        if not {ID_COL, STATUS_COL, WHERE_COL} <= set(header):
            continue
        id_i, st_i, wh_i = (header.index(c) for c in (ID_COL, STATUS_COL, WHERE_COL))
        rows: dict[str, tuple[str, str]] = {}
        for n, row_line in enumerate(lines[i + 2:], start=i + 3):
            row = cells(row_line)
            if row is None:
                break
            if len(row) != len(header):
                raise Refusal(f"{path}:{n}: row has {len(row)} cells, the header has {len(header)}")
            fid = row[id_i]
            if not fid:
                raise Refusal(f"{path}:{n}: row has an empty {ID_COL}")
            if fid in rows:
                raise Refusal(f"{path}:{n}: id {fid} appears twice")
            rows[fid] = (row[st_i], row[wh_i])
        if not rows:
            raise Refusal(f"{path}: the ledger table has no rows")
        return rows
    raise Refusal(
        f"{path}: no recognizable ledger table (a Markdown table whose header names "
        f"'{ID_COL}', '{STATUS_COL}' and '{WHERE_COL}')"
    )


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


def main(argv: list[str]) -> int:
    args = list(argv)
    dry_run = False
    if args and args[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if args and args[0] == "--dry-run":
        dry_run = True
        args = args[1:]
    if len(args) != 2:
        print("usage: fm-audit-landed-by.py [--dry-run] <ledger.md> <decisions.json>", file=sys.stderr)
        return 2
    ledger_path, decisions_path = args
    try:
        ledger = read_ledger(ledger_path)
        with open(decisions_path, encoding="utf-8") as f:
            raw = f.read()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as e:
            raise Refusal(f"{decisions_path}: not valid JSON: {e}") from None
        if not isinstance(data, dict) or not all(isinstance(v, dict) for v in data.values()):
            raise Refusal(f"{decisions_path}: not an object of per-id objects")
        style = dump_style(raw, data)
        missing = [fid for fid in ledger if fid not in data]
        if missing:
            raise Refusal(f"{decisions_path} holds no entry for ledger id(s): {', '.join(missing)}")

        landed = empty = removed = 0
        for fid, (status, where) in ledger.items():
            entry = data[fid]
            if status == "landed":
                urls = list(dict.fromkeys(PR_URL.findall(where)))
                entry[FIELD] = urls
                landed += 1
                empty += not urls
            elif FIELD in entry:
                del entry[FIELD]
                removed += 1

        out = json.dumps(data, indent=style["indent"], ensure_ascii=style["ensure_ascii"]) + style["trailing"]
        changed = out != raw
        print(
            f"landed_by: {landed} landed id(s), {empty} with no PR URL; "
            f"{removed} stale removed; {'would change' if dry_run and changed else 'changed' if changed else 'unchanged'}"
        )
        if changed and not dry_run:
            directory = os.path.dirname(os.path.abspath(decisions_path))
            mode = os.stat(decisions_path).st_mode & 0o7777
            fd, tmp = tempfile.mkstemp(prefix=".landed-by-", dir=directory)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(out)
                os.chmod(tmp, mode)
                os.replace(tmp, decisions_path)
            except BaseException:
                if os.path.exists(tmp):
                    os.unlink(tmp)
                raise
        return 0
    except (Refusal, OSError, UnicodeDecodeError) as e:
        print(f"fm-audit-landed-by: refused: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
