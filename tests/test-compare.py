#!/usr/bin/env python3
"""Offline tests of scripts/compare.py in both schemas, and of scripts/summary.py on schema 3.

    python3 tests/test-compare.py
"""
import copy
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import compare  # noqa: E402

T = tempfile.mkdtemp()
failures = 0
MIRROR = "https://github.com/ReCasaOS/modules/releases/download/"


def check(name, ok, detail=""):
    global failures
    print("%s - %s" % ("ok  " if ok else "FAIL", name))
    if not ok:
        failures += 1
        if detail:
            print(detail)


def entry(name, tag, owner="ReCasaOS", component=None, commit="a" * 40, schema=3):
    component = component or "CasaOS-" + name
    e = {"name": name, "component": component}
    if schema == 3:
        e["repository"] = "%s/%s" % (owner, component)
    e.update({"tier": "core" if owner == "ReCasaOS" else "community", "tag": tag, "commit": commit, "assets": {}, "manifest": {
        "schema": 1, "name": name, "component": component, "unit": "casaos-%s.service" % name, "gateway_route": "/v2/%s" % name,
        "packages": {"common": ["qemu-utils", "ovmf"], "arm64": ["qemu-efi-aarch64"]}}})
    for arch in ("amd64", "arm64"):
        base = "%sm-%s-%s/" % (MIRROR, name, tag) if schema == 3 else "https://github.com/ReCasaOS/%s/releases/download/%s/" % (component, tag)
        e["assets"][arch] = {"url": base + "linux-%s-casaos-%s-%s.tar.gz" % (arch, name, tag), "sha256": "b" * 64}
    return e


def catalogue(modules, schema=3, serial=7, withdrawn=()):
    c = {"schema": schema, "serial": serial, "generated": "2026-11-25T12:00:00Z"}
    if schema == 3:
        c["withdrawn"] = [dict(zip(("name", "tag", "reason"), w)) for w in withdrawn]
    c["modules"] = modules
    return c


counter = [0]


def write(c, directory=None):
    counter[0] += 1
    directory = directory or T
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "c%d.json" % counter[0])
    with open(path, "w") as f:
        f.write(c if isinstance(c, str) else json.dumps(c))
    return path


def refused(c, schema, *words):
    try:
        compare.load(write(c), schema)
    except compare.Refused as err:
        return all(w in str(err) for w in words), str(err)
    return False, "accepted"


def accepted(c, schema):
    try:
        return bool(compare.load(write(c), schema)), ""
    except compare.Refused as err:
        return False, str(err)


good3 = catalogue([entry("virt", "v0.2.6"), entry("hello", "v0.1.0", owner="someone", component="hello-module")],
                  withdrawn=[("virt", "v0.2.5", "The upgrade failed.")])
good2 = catalogue([entry("virt", "v0.2.6", schema=2)], schema=2)

# --- load ----------------------------------------------------------------------------
ok, why = accepted(good3, 3)
check("a valid schema 3 catalogue loads, with a module of another owner", ok, why)
ok, why = accepted(good2, 2)
check("a valid schema 2 catalogue loads as before", ok, why)
check("load(path) is schema 2", sorted(compare.load(write(good2))) == ["virt"])
check("header reads the serial and the time", compare.header(write(good3), 3) == (7, "2026-11-25T12:00:00Z"))
check("a schema 3 catalogue may hold no module and no withdrawn version", compare.load(write(catalogue([])), 3) == {})

m = copy.deepcopy(good3)
del m["withdrawn"]
check("schema 3 without withdrawn is refused", *refused(m, 3, "not a schema 3 catalogue", "withdrawn"))
m = copy.deepcopy(good3)
del m["modules"][0]["repository"]
check("schema 3 without repository is refused", *refused(m, 3, "not a schema 3 catalogue", "modules.0"))
check("a repeated key is refused", *refused(json.dumps(good3).replace('"serial": 7,', '"serial": 7, "serial": 8,'), 3, "a key is repeated"))
check("a schema 2 file given for 3 is refused", *refused(good2, 3, "not a schema 3 catalogue"))
check("a schema 3 file given for 2 is refused", *refused(good3, 2, "not a schema 2 catalogue"))
m = copy.deepcopy(good3)
m["schema"] = 2
check("schema 2 in a schema 3 shape is refused", *refused(m, 3, "schema is 2"))
m = copy.deepcopy(good2)
m["withdrawn"] = []
check("withdrawn in a schema 2 file is refused", *refused(m, 2, "not a schema 2 catalogue"))

for label, mutate, words in (
    ("a commit that is not 40 lower case hex", lambda c: c["modules"][0].update(commit="A" * 40), ("commit",)),
    ("a sha256 that is not 64 lower case hex", lambda c: c["modules"][0]["assets"]["amd64"].update(sha256="B" * 64), ("SHA-256",)),
    ("an architecture that is none of the two", lambda c: c["modules"][0]["assets"].update(riscv=c["modules"][0]["assets"]["amd64"]), ("amd64 and an arm64",)),
    ("only one architecture", lambda c: c["modules"][0]["assets"].pop("arm64"), ("amd64 and an arm64",)),
    ("a name that is not the name of a module", lambda c: c["modules"][1].update(name="Hello"), ("name",)),
    ("a withdrawn name that is not the name of a module", lambda c: c["withdrawn"][0].update(name="A b"), ("withdrawn.0",)),
    ("an archive file of another architecture", lambda c: c["modules"][0]["assets"]["amd64"].update(url=MIRROR + "m-virt-v0.2.6/linux-arm64-casaos-virt-v0.2.6.tar.gz"), ("archive",)),
    ("an archive file of another tag", lambda c: c["modules"][0]["assets"]["amd64"].update(url=MIRROR + "m-virt-v0.2.6/linux-amd64-casaos-virt-v0.2.5.tar.gz"), ("archive",)),
    ("an archive file that is no archive name", lambda c: c["modules"][0]["assets"]["amd64"].update(url=MIRROR + "m-virt-v0.2.6/evil.sh"), ("archive",)),
    ("a reason with an @", lambda c: c["withdrawn"][0].update(reason="Thanks @someone"), ("withdrawn.0", "@")),
    ("a reason with a <!", lambda c: c["withdrawn"][0].update(reason="a <!-- b"), ("withdrawn.0",)),
    ("a reason with a line feed", lambda c: c["withdrawn"][0].update(reason="a\nb"), ("withdrawn.0",)),
    ("a reason of blanks", lambda c: c["withdrawn"][0].update(reason="⠀⠀"), ("withdrawn.0",)),
    ("a withdrawn version that is not a list", lambda c: c.update(withdrawn={}), ("withdrawn",)),
    ("a withdrawn version with another key", lambda c: c["withdrawn"][0].update(why="x"), ("withdrawn.0",)),
    ("a withdrawn version with no reason", lambda c: c["withdrawn"][0].update(reason=""), ("withdrawn.0",)),
    ("a withdrawn reason of 201 characters", lambda c: c["withdrawn"][0].update(reason="x" * 201), ("withdrawn.0",)),
    ("a withdrawn tag written otherwise", lambda c: c["withdrawn"][0].update(tag="0.2.5"), ("withdrawn.0",)),
    ("a version withdrawn twice", lambda c: c["withdrawn"].append(dict(c["withdrawn"][0])), ("twice",)),
    ("65 withdrawn versions", lambda c: c.update(withdrawn=[{"name": "n", "tag": "v0.0.%d" % i, "reason": "r"} for i in range(65)]), ("withdrawn",)),
    ("an owner that is not an account", lambda c: c["modules"][1].update(repository="-bad/hello-module"), ("repository",)),
    ("a repository whose name is not the component", lambda c: c["modules"][1].update(repository="someone/other"), ("repository",)),
    ("a repository with no owner", lambda c: c["modules"][0].update(repository="CasaOS-virt"), ("repository",)),
    ("another owner than ReCasaOS at tier core", lambda c: c["modules"][1].update(tier="core"), ("someone", "community")),
    ("the owner spelled recasaos at tier core", lambda c: c["modules"][0].update(repository="recasaos/CasaOS-virt"), ("recasaos", "community")),
    ("an archive at the author's repository", lambda c: c["modules"][1]["assets"]["amd64"].update(url="https://github.com/someone/hello-module/releases/download/v0.1.0/x.tar.gz"), ("archive",)),
    ("an archive of another version's release", lambda c: c["modules"][0]["assets"]["amd64"].update(url=MIRROR + "m-virt-v0.2.5/x.tar.gz"), ("archive",)),
    ("an archive in a folder of the release", lambda c: c["modules"][0]["assets"]["amd64"].update(url=MIRROR + "m-virt-v0.2.6/a/x.tar.gz"), ("archive",)),
    ("an archive with no file name", lambda c: c["modules"][0]["assets"]["amd64"].update(url=MIRROR + "m-virt-v0.2.6/"), ("archive",)),
    ("a module twice", lambda c: c["modules"].append(copy.deepcopy(c["modules"][0])), ("twice",)),
):
    m = copy.deepcopy(good3)
    mutate(m)
    check("refused: " + label, *refused(m, 3, "not a schema 3 catalogue", *words))

m = copy.deepcopy(good3)
m["withdrawn"] = [{"name": "n", "tag": "v0.0.%d" % i, "reason": "r"} for i in range(64)]
check("64 withdrawn versions pass", *accepted(m, 3))
m = copy.deepcopy(good3)
m["withdrawn"][0]["reason"] = "x" * 200
check("a withdrawn reason of 200 characters passes", *accepted(m, 3))

for label, mutate in (
    ("a commit that is not hex", lambda c: c["modules"][0].update(commit="z" * 40)),
    ("one architecture only", lambda c: c["modules"][0]["assets"].pop("arm64")),
    ("a sha256 of capitals", lambda c: c["modules"][0]["assets"]["amd64"].update(sha256="B" * 64)),
    ("a name that is none", lambda c: c["modules"][0].update(name="Virt!")),
):
    m = copy.deepcopy(good2)
    mutate(m)
    check("refused in schema 2: " + label, *refused(m, 2, "not a schema 2 catalogue"))

# --- compare ---------------------------------------------------------------------------
def run_compare(published, new, *extra):
    p = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts", "compare.py"), write(published), write(new), *extra],
                       capture_output=True, text=True)
    return p.returncode, p.stderr


def moved(tag, new_tag):
    old = catalogue([entry("virt", tag)])
    new = catalogue([entry("virt", new_tag, owner="someone", component="CasaOS-virt")])
    new["modules"][0]["assets"] = old["modules"][0]["assets"] if tag == new_tag else new["modules"][0]["assets"]
    return old, new


old, new = moved("v0.2.6", "v0.2.6")
code, err = run_compare(old, new, "--schema", "3")
check("a repository changed at an equal tag is refused, naming it", code == 1 and "virt" in err and "repository" in err and "someone/CasaOS-virt" in err, err)
old, new = moved("v0.2.6", "v0.2.7")
code, err = run_compare(old, new, "--schema", "3")
check("a repository changed at a higher tag is refused, naming it", code == 1 and "virt" in err and "never changes repository" in err, err)
code, err = run_compare(catalogue([entry("virt", "v0.2.6")]), catalogue([entry("virt", "v0.2.7")]), "--schema", "3")
check("a higher tag at the same repository passes", code == 0, err)
code, err = run_compare(catalogue([entry("virt", "v0.2.6")]), catalogue([entry("virt", "v0.2.6", commit="c" * 40)]), "--schema", "3")
check("a commit changed at an equal tag is refused in schema 3 too", code == 1 and "commit" in err, err)
code, err = run_compare(catalogue([entry("virt", "v0.2.6")]), catalogue([entry("virt", "v0.2.6"), entry("hello", "v0.1.0", owner="someone")]), "--schema", "3")
check("a new module of another owner passes", code == 0, err)
code, err = run_compare(good2, good2)
check("schema 2 is the default of the command line", code == 0, err)
code, err = run_compare(good3, good3)
check("a schema 3 file without --schema is refused as a schema 2", code == 1 and "not a schema 2 catalogue" in err, err)
code, err = run_compare(good2, good2, "--schema", "3")
check("a schema 2 file with --schema 3 is refused", code == 1 and "not a schema 3 catalogue" in err, err)
code, err = run_compare(good3, good3, "--schema", "4")
check("--schema 4 is a usage error", code == 2 and "usage" in err, err)

# --- summary ---------------------------------------------------------------------------
def summary(published, new):
    dirs = []
    for c in (published, new):
        d = tempfile.mkdtemp(dir=T)
        for name, content in (c or {}).items():
            with open(os.path.join(d, name), "w") as f:
                json.dump(content, f)
        dirs.append(d)
    p = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts", "summary.py"), *dirs], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


old3 = catalogue([entry("virt", "v0.2.5", commit="1" * 40)], withdrawn=[("virt", "v0.2.0", "Old.")])
old2 = catalogue([entry("virt", "v0.2.5", commit="1" * 40, schema=2)], schema=2)
new3 = catalogue([entry("virt", "v0.2.6", commit="2" * 40), entry("hello", "v0.1.0", owner="someone", component="hello-module", commit="3" * 40)],
                 withdrawn=[("virt", "v0.2.0", "Old."), ("virt", "v0.2.5", "The upgrade failed.")])
code, out = summary({"catalogue-2.json": old2, "catalogue-3.json": old3}, {"catalogue-2.json": old2, "catalogue-3.json": new3})
check("summary: a new module of another owner shows its repository, packages, unit and route",
      code == 0 and "| hello | - | v0.1.0 (community) | added |" in out and r"repository someone\/hello\-module" in out
      and r"common: qemu\-utils, ovmf; arm64: qemu\-efi\-aarch64" in out and r"unit casaos\-hello\.service" in out and r"route \/v2\/hello" in out, out)
check("summary: a new version links to the comparison of the two commits",
      "https://github.com/ReCasaOS/CasaOS-virt/compare/%s...%s" % ("1" * 40, "2" * 40) in out and "| virt | v0.2.5 (core) | v0.2.6 (core) | updated |" in out, out)
check("summary: a new module has no comparison link", "hello-module/compare" not in out, out)
check("summary: only the withdrawn version that is new is listed", r"- virt v0.2.5: The upgrade failed\." in out and "virt v0.2.0" not in out, out)
check("summary: nothing says first publication when both are published", "first publication" not in out, out)

code, out = summary({"catalogue-2.json": old2}, {"catalogue-2.json": old2, "catalogue-3.json": new3})
check("summary: a published release without catalogue-3.json says so in one line",
      code == 0 and out.count("no catalogue-3.json yet") == 1 and "first publication of schema 3" in out and "| hello | - | v0.1.0 (community) | added |" in out, out)
code, out = summary({}, {"catalogue-2.json": old2, "catalogue-3.json": new3})
check("summary: nothing published yet is the first publication", code == 0 and "No catalogue is published yet" in out and "no catalogue-3.json yet" not in out, out)
code, out = summary({"catalogue-2.json": old2}, {"catalogue-2.json": old2})
check("summary: a new directory without catalogue-3.json says so, as before for schema 2", code == 0 and "No catalogue-3.json is built here" in out and "| virt | v0.2.5 (core) | v0.2.5 (core) | unchanged |" in out, out)
# the summary of a hostile catalogue stays safe
evil = "x](https://evil.example/a) <b>y</b> # head | cell `z` @all www.evil.example"
h_old = catalogue([entry("virt", "v0.2.5", commit="1" * 40)])
h_new = catalogue([entry("virt", "v0.2.6", commit="2" * 40), entry("hello", "v0.1.0", owner="someone", component="hello-module", commit="3" * 40)],
                  withdrawn=[("virt", "v0.2.5", "x](https://evil.example/a) <b>y</b> # head | cell `z` www.evil.example")])
h_new["modules"][1]["manifest"]["packages"] = {"common": [evil], evil: [evil + "\n# head"]}
h_new["modules"][1]["manifest"]["unit"] = "u\n# head"
h_new["modules"][1]["manifest"]["gateway_route"] = evil
code, out = summary({"catalogue-3.json": h_old}, {"catalogue-3.json": h_new})
lines = out.split("\n")
check("summary: a hostile value gives no link, tag, heading, mention or extra line",
      code == 0 and "](" not in out and "<b>" not in out and not re.search(r"(?<!\\)@", out) and "www.evil" not in out and not any(l.startswith("#") and "head" in l for l in lines[1:])
      and sum(l.startswith("- **hello") for l in lines) == 1 and sum(l.startswith("- virt v0.2.5: ") for l in lines) == 1
      and all(l.startswith(("|", "-", "  -", "#")) or not l for l in lines if l != "New versions:" and not l.endswith(":")), out)
check("summary: a hostile reason keeps its pipe from breaking anything", any(l.startswith("- virt v0.2.5: x") and r"\|" in l for l in lines), out)

# a file the strict reader refuses is a sentence and a status, not a traceback
bad = catalogue([entry("virt", "v0.2.6")])
bad["modules"][0]["commit"] = "nothex"
code, out = summary({"catalogue-3.json": bad}, {"catalogue-3.json": good3})
check("summary: a published file that does not pass is refused in one sentence", code == 1 and "Traceback" not in out and out.count("\n") == 1 and "not a schema 3 catalogue" in out, out)
code, out = summary({"catalogue-3.json": good3}, {"catalogue-3.json": json.dumps(good3).replace('"serial": 7,', '"serial": 7, "serial": 8,')})
check("summary: a repeated key is refused in one sentence", code == 1 and "Traceback" not in out, out)

# nothing hidden
same = catalogue([entry("virt", "v0.2.6", commit="1" * 40)])
for label, mutate in (
    ("a repository", lambda e: e.update(repository="someone/CasaOS-virt", tier="community")),
    ("a commit", lambda e: e.update(commit="9" * 40)),
    ("an archive", lambda e: e["assets"]["amd64"].update(sha256="c" * 64)),
    ("a manifest", lambda e: e["manifest"].update(unit="other.service")),
):
    n = copy.deepcopy(same)
    mutate(n["modules"][0])
    code, out = summary({"catalogue-3.json": same}, {"catalogue-3.json": n})
    check("summary: %s changed under the same tag is shown as such" % label, code == 0 and "changed under the same tag" in out and "unchanged" not in out, out)
n = copy.deepcopy(same)
n["modules"][0]["tier"] = "community"
code, out = summary({"catalogue-3.json": same}, {"catalogue-3.json": n})
check("summary: a tier alone is a tier change", "tier changed" in out and "changed under the same tag" not in out, out)

was = catalogue([entry("virt", "v0.2.6")], withdrawn=[("virt", "v0.2.0", "Old."), ("virt", "v0.2.1", "Older.")])
now = catalogue([entry("virt", "v0.2.6")], withdrawn=[("virt", "v0.2.0", "Old.")])
code, out = summary({"catalogue-3.json": was}, {"catalogue-3.json": now})
check("summary: a version no longer withdrawn is listed", "No longer withdrawn:" in out and "- virt v0.2.1" in out and "- virt v0.2.0" not in out and "Newly withdrawn" not in out, out)

print()
if failures:
    print("FAIL: %d test(s)" % failures)
    sys.exit(1)
print("PASS")
