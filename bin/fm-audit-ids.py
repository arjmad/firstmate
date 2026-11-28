#!/usr/bin/env python3
"""fm-audit-ids.py - keep audit finding ids unique across audits.

Usage: fm-audit-ids.py next [--prefix <prefix>]... <prior record>...
       fm-audit-ids.py check <audit record> [<prior record>...]

An audit finding id is `<prefix>-<number>`: a lowercase prefix that starts
with a letter (a1, a7, guidance, sapna, x, cap) and a decimal number, as in
a7-05. An id names one finding of one audit, so a merged PR that names it
lands that finding and no other (bin/fm-audit-landed-by.py). Each prefix's
numbers continue across audits; an earlier audit's ids never change.

next   prints the first free id for each prefix, one per line in prefix
       order, as `<prefix>-<NN>`: one past the highest number any prior
       record holds for it, at least two digits, and `<prefix>-01` for a
       prefix no record holds. The prefixes are those the prior decision
       records hold, plus each --prefix. Brief each auditor with its
       prefix's line, so its findings start there.
check  reads the audit record's ids and exits 1, listing each id with the
       prior record that holds it, when a prior record holds the same prefix
       and number (a7-5 and a7-05 count as one) or the record lists one id
       twice; otherwise it prints one ok line. Run it on the audit's record
       before the walk shows its ids.

Records:
  An audit record is a decision record or a findings list:
    - a JSON object whose values are all objects (decisions.json): each key
      is an id;
    - a JSONL file (`.jsonl`) whose lines are objects: each line's `id` is an
      id.
    Every id must have the `<prefix>-<number>` shape.
  A prior record is an earlier audit's record: a file, or a directory read as
  every regular file directly inside it (one directory per audit, such as
  `data/deep-audit-1126/`). A decision record or findings list counts its ids
  as above; any other file (walk-answers.md, a JSON of another shape) is read
  as text, and an id appearing in it as a whole token (a1-6 does not match
  a1-60, xa1-6 or a1-6-followup) counts for a prefix a decision record or
  --prefix names. Counting an id an old record only cites is harmless: it
  only moves the next free number higher.
  check skips the audit record itself and a prior directory that holds it,
  because that directory is the same audit's, so a glob over every audit
  directory may include the current one; any other file named is a prior.

Exit codes: 0 next printed, or check found no shared id; 1 check found a
shared or repeated id, or a refusal (a missing or unreadable record, an audit
record that is neither shape, an id of another shape); 2 a bad command line.
It writes nothing.
"""

from __future__ import annotations

import json
import os
import re
import sys

ID = re.compile(r"^([a-z][a-z0-9]*)-([0-9]+)$")
TOKEN = re.compile(r"(?<![A-Za-z0-9_-])([a-z][a-z0-9]*)-([0-9]+)(?![A-Za-z0-9_-])")
USAGE = (
    "usage: fm-audit-ids.py next [--prefix <prefix>]... <prior record>...\n"
    "       fm-audit-ids.py check <audit record> [<prior record>...]"
)


class Refusal(RuntimeError):
    pass


class Usage(RuntimeError):
    pass


def split_id(fid: str) -> tuple[str, int] | None:
    m = ID.match(fid)
    return (m.group(1), int(m.group(2))) if m else None


def structured_ids(path: str, text: str) -> list[str] | None:
    """The ids a decision record or findings list holds, or None for another file."""
    if path.endswith(".jsonl"):
        ids = []
        for n, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                return None
            if not isinstance(row, dict) or not isinstance(row.get("id"), str):
                return None
            ids.append(row["id"])
        return ids
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None
    if isinstance(data, dict) and all(isinstance(v, dict) for v in data.values()):
        return list(data)
    return None


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise Refusal(f"{path}: cannot read: {e}") from None


def prior_files(paths: list[str]) -> list[str]:
    files = []
    for path in paths:
        if os.path.isdir(path):
            files += sorted(os.path.join(path, name) for name in os.listdir(path)
                            if os.path.isfile(os.path.join(path, name)))
        elif os.path.isfile(path):
            files.append(path)
        else:
            raise Refusal(f"{path}: no such record or directory")
    return files


class Holdings:
    """Every (prefix, number) the prior records hold, and which record holds it."""

    def __init__(self, paths: list[str]) -> None:
        self.ids: dict[tuple[str, int], str] = {}
        self.texts: list[tuple[str, str]] = []
        self.prefixes: set[str] = set()
        for path in paths:
            text = read_text(path)
            ids = structured_ids(path, text)
            if ids is None:
                self.texts.append((path, text))
                continue
            for fid in ids:
                key = split_id(fid)
                if key:
                    self.ids.setdefault(key, path)
                    self.prefixes.add(key[0])

    def holder(self, key: tuple[str, int]) -> str | None:
        if key in self.ids:
            return self.ids[key]
        for path, text in self.texts:
            if any((m.group(1), int(m.group(2))) == key for m in TOKEN.finditer(text)):
                return path
        return None

    def highest(self, prefix: str) -> int:
        top = max((n for p, n in self.ids if p == prefix), default=0)
        for _, text in self.texts:
            for m in TOKEN.finditer(text):
                if m.group(1) == prefix:
                    top = max(top, int(m.group(2)))
        return top


def cmd_next(argv: list[str]) -> int:
    prefixes: list[str] = []
    paths: list[str] = []
    it = iter(argv)
    for arg in it:
        if arg == "--prefix":
            value = next(it, None)
            if value is None or not re.match(r"^[a-z][a-z0-9]*$", value):
                raise Usage("--prefix needs a lowercase prefix that starts with a letter, such as a7")
            prefixes.append(value)
        elif arg.startswith("--"):
            raise Usage(f"unknown option {arg}")
        else:
            paths.append(arg)
    held = Holdings(prior_files(paths))
    wanted = sorted(held.prefixes | set(prefixes))
    if not wanted:
        raise Usage("next needs a prior decision record or a --prefix")
    for prefix in wanted:
        print(f"{prefix}-{held.highest(prefix) + 1:02d}")
    return 0


def cmd_check(argv: list[str]) -> int:
    if not argv or any(a.startswith("--") for a in argv):
        raise Usage("check needs one audit record, then its prior records")
    record, priors = argv[0], argv[1:]
    if not os.path.isfile(record):
        raise Refusal(f"{record}: no such audit record")
    ids = structured_ids(record, read_text(record))
    if ids is None:
        raise Refusal(f"{record}: neither a decision record (an object of per-id objects) "
                      "nor a findings list (.jsonl lines with an id)")
    bad = [fid for fid in ids if not split_id(fid)]
    if bad:
        raise Refusal(f"{record}: not <prefix>-<number> id(s): {', '.join(bad)}")
    own = os.path.realpath(record)
    own_dir = os.path.dirname(own)
    priors = [p for p in priors if not (os.path.isdir(p) and os.path.realpath(p) == own_dir)]
    files = [p for p in prior_files(priors) if os.path.realpath(p) != own]
    held = Holdings(files)
    problems = []
    seen: dict[tuple[str, int], str] = {}
    for fid in ids:
        key = split_id(fid)
        assert key is not None
        if key in seen:
            problems.append(f"{fid} (listed twice, as {seen[key]} and {fid})")
            continue
        seen[key] = fid
        holder = held.holder(key)
        if holder:
            problems.append(f"{fid} (a prior audit holds it: {holder})")
    if problems:
        print(f"fm-audit-ids: {record}: {len(problems)} id(s) another audit or this record already uses; "
              "renumber each from `fm-audit-ids.py next`:", file=sys.stderr)
        for line in problems:
            print(f"  {line}", file=sys.stderr)
        return 1
    print(f"ok: {len(ids)} id(s) in {record}, none in {len(files)} prior record(s)")
    return 0


def main(argv: list[str]) -> int:
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip())
        return 0
    if not argv:
        print(f"fm-audit-ids: needs next or check\n{USAGE}", file=sys.stderr)
        return 2
    try:
        if argv[0] == "next":
            return cmd_next(argv[1:])
        if argv[0] == "check":
            return cmd_check(argv[1:])
        raise Usage(f"unknown command {argv[0]}")
    except Usage as e:
        print(f"fm-audit-ids: {e}\n{USAGE}", file=sys.stderr)
        return 2
    except Refusal as e:
        print(f"fm-audit-ids: refused: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
