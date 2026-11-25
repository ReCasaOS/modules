#!/usr/bin/env python3
"""Offline tests of scripts/names.py: a retired module keeps its name, its unit and its route for ever.

    python3 tests/test-names.py
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAMES = os.path.join(ROOT, "scripts", "names.py")
T = tempfile.mkdtemp()
failures = 0
counter = [0]


def check(name, ok, detail=""):
    global failures
    print("%s - %s" % ("ok  " if ok else "FAIL", name))
    if not ok:
        failures += 1
        if detail:
            print(detail)


def assets(name):
    base = "https://github.com/ReCasaOS/modules/releases/download/m-%s-v0.1.0/" % name
    return {a: {"url": base + "linux-%s-casaos-%s-v0.1.0.tar.gz" % (a, name), "sha256": "b" * 64} for a in ("amd64", "arm64")}


def entry(name, unit=None, route="default"):
    manifest = {"schema": 1, "name": name, "unit": unit or "casaos-%s.service" % name}
    if route == "default":
        route = "/v2/%s" % name.replace("-", "_")
    if route:
        manifest["gateway_route"] = route
    return {"name": name, "component": "CasaOS-" + name, "repository": "ReCasaOS/CasaOS-" + name, "tier": "core", "tag": "v0.1.0",
            "commit": "a" * 40, "assets": assets(name), "manifest": manifest}


def write(text):
    counter[0] += 1
    path = os.path.join(T, "f%d" % counter[0])
    with open(path, "w") as f:
        f.write(text)
    return path


def catalogue(*modules):
    return write(json.dumps({"schema": 3, "serial": 1, "generated": "2026-11-25T12:00:00Z", "withdrawn": [], "modules": list(modules)}))


def run(*args):
    p = subprocess.run([sys.executable, "-I", NAMES, *args], capture_output=True, text=True)
    return p.returncode, p.stderr.strip()


HEADER = "# retired modules\n\n"
retired = write(HEADER + "old casaos-old.service /v2/old\nnoroute casaos-noroute.service -\n")
empty = write(HEADER)

# the shipped file holds its header only: nothing is retired, nothing is refused
shipped = os.path.join(ROOT, "retired.env")
rc, err = run(catalogue(entry("virt")), shipped)
check("the shipped retired.env is accepted and empty", rc == 0 and err == "", err)

rc, err = run(catalogue(entry("virt")), retired)
check("a new module with free names passes", rc == 0 and err == "", err)

rc, err = run(catalogue(entry("old", "x.service", "/v2/x")), retired)
check("a retired name is refused, named", rc == 1 and "old" in err and "name" in err, err)

rc, err = run(catalogue(entry("fresh", "casaos-old.service", "/v2/fresh")), retired)
check("a retired unit is refused, named", rc == 1 and "casaos-old.service" in err, err)

rc, err = run(catalogue(entry("fresh", "fresh.service", "/v2/old")), retired)
check("a retired route is refused, named", rc == 1 and "/v2/old" in err, err)

rc, err = run(catalogue(entry("fresh", route=None)), retired)
check("a module with no route is not stopped by the '-' of a line", rc == 0, err)

# the published catalogue: a module that went must be retired with its own name, unit and route
pub = catalogue(entry("old"), entry("noroute", route=None), entry("kept"))
new = catalogue(entry("kept"))
rc, err = run(new, retired, pub)
check("a module removed and retired by its own line passes", rc == 0 and err == "", err)

rc, err = run(new, empty, pub)
check("a module removed with no line is refused, named", rc == 1 and "Module noroute" in err, err)

other = write(HEADER + "old other.service /v2/old\nnoroute casaos-noroute.service -\n")
rc, err = run(new, other, pub)
check("a retired line with another unit is refused", rc == 1 and "old" in err and "unit" in err, err)

other = write(HEADER + "old casaos-old.service /v2/other\nnoroute casaos-noroute.service -\n")
rc, err = run(new, other, pub)
check("a retired line with another route is refused", rc == 1 and "old" in err and "route" in err, err)

other = write(HEADER + "old old.service /v2/old\nnoroute casaos-noroute.service /v2/noroute\n")
rc, err = run(new, other, pub)
check("a retired line with a route for a module without one is refused", rc == 1 and "noroute" in err, err)

rc, err = run(catalogue(entry("kept"), entry("old")), retired, pub)
check("a module still listed needs no line (its name is then refused as retired)", rc == 1 and "old" in err, err)

# a malformed retired.env refuses the file
for label, text in (
    ("two words", "old old.service\n"),
    ("four words", "old old.service /v2/old more\n"),
    ("a name out of the pattern", "Old old.service /v2/old\n"),
    ("a unit out of the pattern", "old old /v2/old\n"),
    ("a route out of the pattern", "old old.service v2/old\n"),
    ("a name twice", "old a.service /v2/a\nold b.service /v2/b\n"),
    ("a unit twice", "a a.service /v2/a\nb a.service /v2/b\n"),
    ("a route twice", "a a.service /v2/a\nb b.service /v2/a\n"),
    ("a trailing comment", "old old.service /v2/old # why\n"),
):
    rc, err = run(catalogue(entry("virt")), write(HEADER + text))
    check("retired.env refused: " + label, rc == 1 and "retired.env" in err, err)

rc, err = run(catalogue(entry("virt")), write(HEADER + "a a.service -\nb b.service -\n"))
check("'-' may appear in several lines", rc == 0, err)

rc, err = run(catalogue(entry("virt")), os.path.join(T, "missing"))
check("a missing retired.env is refused", rc == 1, err)

rc, err = run(write("{}"), retired)
check("a catalogue that is not schema 3 is refused", rc == 1 and err, err)

rc, err = run(catalogue(entry("fresh", "fresh.service", "/v3/old")), retired)
check("a retired route is reserved under another API version", rc == 1 and "/v3/old" in err, err)

other = write(HEADER + "old casaos-old.service /v3/old" + chr(10) + "noroute casaos-noroute.service -" + chr(10))
rc, err = run(new, other, pub)
check("a retired line may name the route under another API version", rc == 0, err)

rc, err = run(catalogue(entry("virt")), write(HEADER + "a a.service /v2/a" + chr(10) + "b b.service /v3/a" + chr(10)))
check("retired.env refused: a route twice under two versions", rc == 1 and "retired.env" in err, err)

for label, bad_entry in (("a unit that is a number", entry("virt", unit=5)), ("a route that is a list", entry("virt", route=["/v2/x"]))):
    rc, err = run(catalogue(bad_entry), retired)
    check("new catalogue with " + label + ": one sentence", rc == 1 and "Traceback" not in err and "virt" in err and chr(10) not in err, err)
    rc, err = run(new, retired, catalogue(bad_entry, entry("kept")))
    check("published catalogue with " + label + ": one sentence", rc == 1 and "Traceback" not in err and "virt" in err and chr(10) not in err, err)

rc, err = run()
check("no argument is usage", rc == 2 and "usage" in err, err)

sys.exit(1 if failures else 0)
