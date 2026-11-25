#!/usr/bin/env python3
"""Prints in Markdown what a change does to the published catalogue of the modules.

    scripts/summary.py OLD_CATALOGUE NEW_CATALOGUE

OLD_CATALOGUE is the catalogue published now; when that file does not exist, nothing is published yet. Each module is listed with its tag and tier before and after:
added, removed, updated, changed at the same tag (another commit or other archives) or unchanged. A catalogue with no module, and a module removed, are said plainly: a merge publishes them to every box.
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
    if not new:
        lines += ["**No module**: this catalogue lists no module. Once merged, no box can install any module.", ""]
    lines += ["| Module | Before | After | Change |", "| --- | --- | --- | --- |"]
    for name in sorted(old.keys() | new.keys()):
        before, after = old.get(name), new.get(name)
        if not before:
            change = "added"
        elif not after:
            change = "**removed**"
        elif cell(before) != cell(after):
            change = "updated"
        elif before != after:
            # same tag and tier, yet the entry differs: the release was replaced, or its commit re-pinned
            change = "**changed at the same tag**: " + ", ".join(sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k)))
        else:
            change = "unchanged"
        lines.append("| %s | %s | %s | %s |" % (name, cell(before), cell(after), change))
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: scripts/summary.py OLD_CATALOGUE NEW_CATALOGUE")
    main(sys.argv[1], sys.argv[2])
