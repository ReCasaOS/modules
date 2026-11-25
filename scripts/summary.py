#!/usr/bin/env python3
"""Prints in Markdown what a change does to the published catalogues of the modules.

    scripts/summary.py PUBLISHED_DIR NEW_DIR

Each directory holds catalogue-2.json and, from the first publication of schema 3, catalogue-3.json. PUBLISHED_DIR is what scripts/published.sh wrote: when it holds
no catalogue-2.json, nothing is published yet. Each module is listed with its tag and tier before and after: added, removed, updated (a higher tag), changed under the
same tag (a repository, commit, archive or manifest that differs, which compare.py refuses), tier changed or unchanged; a module removed is said plainly, a merge
publishes that to every box. The schema 3 file of a directory, when it has one, is the one read, as it holds the modules of other owners too. Below the table, each module
added or updated says its repository, packages, unit and route, an update links to what changed in its repository, and the withdrawn versions that are new, and those
that are no longer, are listed.

Both sides are read by the strict reader of scripts/compare.py (a file that does not pass is one sentence on the standard error and exit status 1), and every value taken
from a catalogue is escaped for Markdown before it is printed (a name and a tag only after compare.py matched their patterns), so that none can open a link, start a heading or break a line or a table row.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare  # noqa: E402

REPOSITORY_RE = re.compile(r"[A-Za-z0-9-]+/[A-Za-z][A-Za-z0-9._-]*")


def read(directory):
    """(the catalogue read in directory, whether it is schema 3): {} when there is none, which is nothing published."""
    for name, schema in (("catalogue-3.json", 3), ("catalogue-2.json", 2)):
        path = os.path.join(directory, name)
        if os.path.exists(path):
            return compare.read(path, schema), schema == 3
    return {}, False


def md(value):
    """A value of a catalogue as Markdown text: ASCII punctuation escaped, anything but letters, digits, marks, symbols and a space made a space or a question mark."""
    out = []
    for c in str(value):
        if c.isascii() and not c.isalnum() and c != " " and c.isprintable():
            out.append("\\" + c)
        elif c == " " or c.isalnum() or (c.isprintable() and not c.isascii() and c not in "  "):
            out.append(c)
        else:
            out.append("?")
    return "".join(out)


def cell(m):
    return "%s (%s)" % (m["tag"], md(m["tier"])) if m else "-"  # a tag has the pattern of compare.py


def packages(manifest):
    pk = manifest.get("packages")
    if not isinstance(pk, dict) or not pk:
        return "none"
    return "; ".join("%s: %s" % (md(arch), ", ".join(md(n) for n in names) if isinstance(names, list) else md(names)) for arch, names in pk.items())


def details(old, new):
    repository = new.get("repository") or "ReCasaOS/" + str(new.get("component"))
    manifest = new["manifest"]
    lines = ["- **%s %s**: repository %s, packages %s, unit %s, route %s" % (
        new["name"], new["tag"], md(repository), packages(manifest), md(manifest.get("unit", "none")), md(manifest.get("gateway_route", "none")))]
    if old and REPOSITORY_RE.fullmatch(repository):
        # the commits are 40 hexadecimal digits (compare.py) and the repository is checked just above: nothing to escape
        lines.append("  - changes: https://github.com/%s/compare/%s...%s" % (repository, old["commit"], new["commit"]))
    return lines


def main(published_dir, new_dir):
    try:
        (old_c, old3), (new_c, new3) = read(published_dir), read(new_dir)
    except compare.Refused as err:
        sys.exit(str(err))
    old = {m["name"]: m for m in old_c.get("modules", [])}
    new = {m["name"]: m for m in new_c.get("modules", [])}

    lines = ["## Modules catalogue", ""]
    if not old_c:
        lines += ["No catalogue is published yet: this is the first publication.", ""]
    elif not old3:
        lines += ["The published release has no catalogue-3.json yet: this is the first publication of schema 3.", ""]
    if not new3:
        lines += ["No catalogue-3.json is built here: only the modules of ReCasaOS are listed.", ""]
    lines += ["| Module | Before | After | Change |", "| --- | --- | --- | --- |"]
    news = []
    for name in sorted(old.keys() | new.keys()):
        before, after = old.get(name), new.get(name)
        if not before:
            change = "added"
        elif not after:
            change = "**removed**"
        elif before["tag"] != after["tag"]:
            change = "updated"  # compare.py lets through only a higher tag
        elif any(before.get(k) != after.get(k) for k in before.keys() | after.keys() if k != "tier"):
            change = "**changed under the same tag**"  # compare.py refuses it
        elif before["tier"] != after["tier"]:
            change = "tier changed"
        else:
            change = "unchanged"
        if change in ("added", "updated"):
            news += details(before, after)
        lines.append("| %s | %s | %s | %s |" % (name, cell(before), cell(after), change))
    if news:
        lines += ["", "New versions:", ""] + news
    old_w = {(w["name"], w["tag"]) for w in old_c.get("withdrawn", [])}
    new_w = {(w["name"], w["tag"]) for w in new_c.get("withdrawn", [])}
    withdrawn = ["- %s %s: %s" % (w["name"], w["tag"], md(w["reason"])) for w in new_c.get("withdrawn", []) if (w["name"], w["tag"]) not in old_w]
    if withdrawn:
        lines += ["", "Newly withdrawn versions:", ""] + withdrawn
    if new3:
        back = ["- %s %s" % (n, t) for n, t in sorted(old_w - new_w)]
        if back:
            lines += ["", "No longer withdrawn:", ""] + back
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: scripts/summary.py PUBLISHED_DIR NEW_DIR")
    main(sys.argv[1], sys.argv[2])
