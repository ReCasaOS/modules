#!/usr/bin/env python3
"""Prints in Markdown what a change does to the published catalogue of the modules.

    scripts/summary.py OLD_CATALOGUE NEW_CATALOGUE

OLD_CATALOGUE is the catalogue published now; when that file does not exist, nothing is published yet. Each module is listed with its tag and tier before and after:
added, removed, updated (a higher tag), tier changed or unchanged. A module removed is said plainly: a merge publishes that to every box. NEW is the catalogue that
scripts/build.sh built (and checked against OLD with scripts/compare.py).
"""
import json
import os
import sys


def modules(path):
    with open(path, encoding="utf-8") as f:
        return {m["name"]: m for m in json.load(f)["modules"]}


def cell(m):
    return "%s (%s)" % (m["tag"], m["tier"]) if m else "-"


def main(old_path, new_path):
    new = modules(new_path)
    first = not os.path.exists(old_path)
    old = {} if first else modules(old_path)

    lines = ["## Modules catalogue", ""]
    if first:
        lines += ["No catalogue is published yet: this is the first publication.", ""]
    lines += ["| Module | Before | After | Change |", "| --- | --- | --- | --- |"]
    for name in sorted(old.keys() | new.keys()):
        before, after = old.get(name), new.get(name)
        if not before:
            change = "added"
        elif not after:
            change = "**removed**"
        elif before["tag"] != after["tag"]:
            change = "updated"  # compare.py lets through only a higher tag
        elif before["tier"] != after["tier"]:
            change = "tier changed"
        else:
            change = "unchanged"
        lines.append("| %s | %s | %s | %s |" % (name, cell(before), cell(after), change))
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: scripts/summary.py OLD_CATALOGUE NEW_CATALOGUE")
    main(sys.argv[1], sys.argv[2])
