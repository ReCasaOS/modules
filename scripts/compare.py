#!/usr/bin/env python3
"""Checks a new catalogue against the one already published:

    scripts/compare.py PUBLISHED NEW [--schema 2|3]

A release may not change under a tag that is already published: every box that read the published catalogue trusts those digests. So a module of NEW
at the same tag as in PUBLISHED must have the same commit, the same archives (url and sha256 for each architecture) and the same manifest; only its tier
may change (a decision recorded in modules.env). A new release needs a new tag. And a module's tag never goes down, nor is written otherwise
(v0.2.06 for v0.2.6): only a numerically higher tag passes, so a bad version is corrected by a higher one.

PUBLISHED is data downloaded from the web: it is parsed strictly, and anything but a catalogue of the schema asked for (2 unless --schema 3) is refused. Schema 3 is the
format open to other owners: schema 2 plus a "withdrawn" list, and a "repository" (<owner>/<component>) in each entry, which a module never changes, at any tag. Exit status: 0 fine, 1 refused (one
sentence on the standard error), 2 usage. scripts/build.sh runs this when it is given PUBLISHED, before it writes anything.
"""
import json
import re
import sys

MAX_BYTES = 1 << 20  # the core's limit on a catalogue
MAX_SERIAL = 1 << 63  # the builder's bound: a serial is a signed 64-bit integer
GENERATED_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
TAG_RE = re.compile(r"v([0-9]+)\.([0-9]+)\.([0-9]+)")
OWNER = "ReCasaOS"
OWNER_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?")
MIRROR_URL = "https://github.com/ReCasaOS/modules/releases/download/"
MAX_WITHDRAWN = 64
MAX_REASON = 200


class Refused(Exception):
    pass


def no_duplicates(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("a key is repeated")
    return dict(pairs)


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def read(path, schema=2):
    """The catalogue at path as the object it is, or Refused when it is not a catalogue of this schema."""
    def bad(why):
        return Refused("%s is not a schema %d catalogue (%s)." % (path, schema, why))

    try:
        with open(path, "rb") as f:
            raw = f.read(MAX_BYTES + 1)
    except OSError:
        raise bad("it cannot be read")
    if len(raw) > MAX_BYTES:
        raise bad("larger than 1 MiB")
    try:
        c = json.loads(raw.decode("utf-8"), object_pairs_hook=no_duplicates)
    except (UnicodeDecodeError, ValueError) as err:
        raise bad("not JSON: %s" % err)
    keys = {"schema", "serial", "generated", "modules"} | ({"withdrawn"} if schema == 3 else set())
    if not isinstance(c, dict) or set(c) != keys:
        raise bad("not an object of %s" % ("schema, serial, generated, withdrawn and modules" if schema == 3 else "schema, serial, generated and modules"))
    if not is_int(c["schema"]) or c["schema"] != schema:
        raise bad("schema is %s" % json.dumps(c["schema"]))
    if not is_int(c["serial"]) or not 1 <= c["serial"] < MAX_SERIAL:
        raise bad("serial is not a positive integer below 2^63")
    if not isinstance(c["generated"], str) or not GENERATED_RE.fullmatch(c["generated"]):
        raise bad("generated is not a UTC time")
    if not isinstance(c["modules"], list):
        raise bad("modules is not a list")
    if schema == 3:
        check_withdrawn(c["withdrawn"], bad)
    names = set()
    for i, e in enumerate(c["modules"]):
        if not (isinstance(e, dict) and all(isinstance(e.get(k), str) for k in ("name", "tag", "commit", "tier") + (("repository",) if schema == 3 else ()))
                and isinstance(e.get("manifest"), dict) and isinstance(e.get("assets"), dict)
                and all(isinstance(a, dict) and isinstance(a.get("url"), str) and isinstance(a.get("sha256"), str) for a in e["assets"].values())):
            raise bad("modules.%d is not a module entry" % i)
        if not TAG_RE.fullmatch(e["tag"]):
            raise bad("module %s has the tag %s" % (e["name"], json.dumps(e["tag"])))
        if e["name"] in names:
            raise bad("module %s is listed twice" % e["name"])
        names.add(e["name"])
        if schema == 3:
            check_entry3(e, bad)
    return c


def check_withdrawn(items, bad):
    if not isinstance(items, list) or len(items) > MAX_WITHDRAWN:
        raise bad("withdrawn is not a list of %d at most" % MAX_WITHDRAWN)
    seen = set()
    for i, w in enumerate(items):
        if not (isinstance(w, dict) and set(w) == {"name", "tag", "reason"} and all(isinstance(v, str) for v in w.values())):
            raise bad("withdrawn.%d is not a name, a tag and a reason" % i)
        if not TAG_RE.fullmatch(w["tag"]) or not 1 <= len(w["reason"]) <= MAX_REASON:
            raise bad("withdrawn.%d has a tag that is none, or a reason of another length than 1 to %d characters" % (i, MAX_REASON))
        if (w["name"], w["tag"]) in seen:
            raise bad("withdrawn.%d withdraws %s %s twice" % (i, w["name"], w["tag"]))
        seen.add((w["name"], w["tag"]))


def check_entry3(e, bad):
    owner, _, repo = e["repository"].partition("/")
    if not OWNER_RE.fullmatch(owner) or not isinstance(e.get("component"), str) or repo != e["component"]:
        raise bad("module %s has the repository %s" % (e["name"], json.dumps(e["repository"])))
    if owner != OWNER and e["tier"] != "community":
        raise bad("module %s is of %s and its tier is %s, not community" % (e["name"], owner, json.dumps(e["tier"])))
    prefix = "%sm-%s-%s/" % (MIRROR_URL, e["name"], e["tag"])
    for arch, a in e["assets"].items():
        file = a["url"][len(prefix):]
        if not a["url"].startswith(prefix) or not file or "/" in file:
            raise bad("module %s, %s: the archive is not at %s" % (e["name"], arch, prefix))


def load(path, schema=2):
    """The catalogue at path as {name: entry}, or Refused when it is not a catalogue of this schema."""
    return {e["name"]: e for e in read(path, schema)["modules"]}


def header(path, schema=2):
    """(serial, generated) of the catalogue at path."""
    c = read(path, schema)
    return c["serial"], c["generated"]


def compare(published, new):
    for name, n in sorted(new.items()):
        p = published.get(name)
        if p is None:
            continue
        if p.get("repository") != n.get("repository"):
            raise Refused("Module %s: the repository is %s, published as %s; a module never changes repository: remove its name and enter another." % (name, n.get("repository"), p.get("repository")))
        # compared as numbers: v0.10.0 is after v0.9.0, and v0.2.06 is v0.2.6
        published_tag, new_tag = (tuple(map(int, TAG_RE.fullmatch(e["tag"]).groups())) for e in (p, n))
        if new_tag < published_tag:
            raise Refused("Module %s: the tag %s is lower than the published %s; the catalogue never goes back: a correction is a new, higher tag." % (name, n["tag"], p["tag"]))
        if new_tag == published_tag and n["tag"] != p["tag"]:
            raise Refused("Module %s: the tag %s is the published %s written otherwise; a correction is a new, higher tag." % (name, n["tag"], p["tag"]))
        if new_tag > published_tag:
            continue
        rule = "a release may not change under a tag already published: give it a new tag."
        where = "Module %s, tag %s" % (name, n["tag"])
        if p["commit"] != n["commit"]:
            raise Refused("%s: the commit is %s, published as %s; %s" % (where, n["commit"], p["commit"], rule))
        for arch in sorted(p["assets"].keys() | n["assets"].keys()):
            pa, na = p["assets"].get(arch), n["assets"].get(arch)
            if pa is None or na is None:
                raise Refused("%s, %s: the archive is %s; %s" % (where, arch, "new" if pa is None else "gone", rule))
            for field in ("sha256", "url"):
                if pa[field] != na[field]:
                    raise Refused("%s, %s: the archive's %s differs from the published one; %s" % (where, arch, field, rule))
            if pa != na:
                raise Refused("%s, %s: the archive differs from the published one; %s" % (where, arch, rule))
        if p["manifest"] != n["manifest"]:
            raise Refused("%s: the manifest differs from the published one; %s" % (where, rule))
        if set(p) - {"tier"} != set(n) - {"tier"} or any(p[k] != n[k] for k in set(p) - {"tier"}):
            raise Refused("%s: the entry differs from the published one; %s" % (where, rule))


def main(argv):
    schema = 2
    if len(argv) == 4 and argv[2] == "--schema" and argv[3] in ("2", "3"):
        schema, argv = int(argv[3]), argv[:2]
    if len(argv) != 2:
        print("usage: scripts/compare.py PUBLISHED NEW [--schema 2|3]", file=sys.stderr)
        return 2
    try:
        compare(load(argv[0], schema), load(argv[1], schema))
    except Refused as err:
        print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
