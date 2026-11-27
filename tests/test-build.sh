#!/usr/bin/env bash
# Offline tests of scripts/build.sh and scripts/summary.py. No network: the
# installer and the core are small fake git repositories made here, handed to
# build.sh through its test-only variables; the files of the module releases are
# read from a local folder (file://), and gh is a fake that notes its arguments.
# Needs bash, git, python3, go and tar. Linux: a bound on the size of a file is
# made with ulimit.
#
#   bash tests/test-build.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export GOPROXY=off GOFLAGS=-mod=mod GOTOOLCHAIN=local

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

commit_all() { # commit_all DIR MESSAGE: prints the new commit
    git -C "$1" add -A &&
        git -C "$1" -c user.name=test -c user.email=test@invalid commit -qm "$2" &&
        git -C "$1" rev-parse HEAD
}

# --- the fake installer: the two scripts build.sh calls ---------------------
inst="${T}/installer"
mkdir -p "${inst}/scripts"
git -C "${inst}" init -q -b main
git -C "${inst}" config uploadpack.allowAnySHA1InWant true
cat >"${inst}/scripts/stage-modules.sh" <<'EOF'
#!/usr/bin/env bash
# fake: stages, with curl, the files that FAKE_FILES/<name>/ holds for each module that `list` prints (so a module that is carried is not
# staged), and says the variables it was given; FAKE_BAD_SUM=<module> says what the real one says when an archive does not match
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "fake stage: OWNERS_BASE_URL=${OWNERS_BASE_URL:-} CARRY_CATALOGUE=${CARRY_CATALOGUE:-}"
if [[ -n "${FAKE_BAD_SUM:-}" ]]; then
    echo "Module ${FAKE_BAD_SUM}: linux-amd64-casaos-${FAKE_BAD_SUM}-v0.0.1.tar.gz is not the archive that checksums.txt names." >&2
    exit 1
fi
mkdir -p "$2"
if [[ -n "${FAKE_STAGE_FAILS_LATE:-}" ]]; then
    echo "Failed to download the checksums of module x." >&2
    exit 1
fi
carry=()
[[ -z "${CARRY_CATALOGUE:-}" ]] || carry=(--carry "${CARRY_CATALOGUE}")
list="$(python3 "${here}/build-modules-catalogue.py" list "$1" ${carry[@]+"${carry[@]}"})"
while read -r name component tag commit tier owner; do
    [[ -n "${name}" ]] || continue
    mkdir -p "$2/${name}"
    for file in checksums.txt "linux-amd64-casaos-${name}-${tag}.tar.gz" "linux-arm64-casaos-${name}-${tag}.tar.gz"; do
        curl -fsS -o "$2/${name}/${file}" "file://${FAKE_FILES}/${name}/${file}" || { echo "Failed to download ${file} of module ${name}." >&2; exit 1; }
    done
done <<<"${list}"
EOF
cat >"${inst}/scripts/build-modules-catalogue.py" <<'EOF'
#!/usr/bin/env python3
# fake: list, build (schema 2, schema 3) and proof, with made-up digests; each accepts only the forms that build.sh must use
import hashlib, json, os, re, sys

def modules(path):
    found = {}
    for line in open(path):
        m = re.fullmatch(r"MODULE_([A-Z0-9_]+)_(TAG|COMMIT|COMPONENT|TIER|OWNER)=(\S+)\n?", line)
        if m:
            found.setdefault(m[1].lower().replace("_", "-"), {"owner": "ReCasaOS"})[m[2].lower()] = m[3]
    return [dict(name=n, **v) for n, v in sorted(found.items())]

def carried(path):
    return {e["name"]: e for e in json.load(open(path))["modules"]}

def is_carried(m, c):
    return m["owner"] != "ReCasaOS" and m["name"] in c and c[m["name"]]["tag"] == m["tag"]

def entry(m, schema, stage):
    if schema == 3:
        base = "https://github.com/ReCasaOS/modules/releases/download/m-%s-%s/" % (m["name"], m["tag"])
    else:
        base = "https://github.com/ReCasaOS/%s/releases/download/%s/" % (m["component"], m["tag"])
    assets = {arch: {"url": "%slinux-%s-casaos-%s-%s.tar.gz" % (base, arch, m["name"], m["tag"]),
                     "sha256": hashlib.sha256(open(os.path.join(stage, m["name"], "linux-%s-casaos-%s-%s.tar.gz" % (arch, m["name"], m["tag"])), "rb").read()).hexdigest()} for arch in ("amd64", "arm64")}
    e = dict(name=m["name"], tag=m["tag"], commit=m["commit"], tier=m["tier"], component=m["component"])
    if schema == 3:
        e["repository"] = "%s/%s" % (m["owner"], m["component"])
    return dict(e, assets=assets, manifest={"name": m["name"], "title": m["name"], "unit": "casaos-%s.service" % m["name"]})

def withdrawn(path):
    items = []
    for line in open(path):
        if line.strip() and not line.startswith("#"):
            name, tag, reason = line.rstrip("\n").split(" ", 2)
            items.append({"name": name, "tag": tag, "reason": reason})
    return items

a = sys.argv[1:]
if a[:1] == ["list"] and (len(a) == 2 or (len(a) == 4 and a[2] == "--carry")):
    c = carried(a[3]) if len(a) == 4 else {}
    for m in modules(a[1]):
        if not is_carried(m, c):
            print(m["name"], m["component"], m["tag"], m["commit"], m["tier"], m["owner"])
elif a[:1] == ["build"] and len(a) >= 5:
    opts = dict(zip(a[1:-2:2], a[2:-2:2]))
    base = {"--git-base", "--out", "--schema", "--serial", "--generated"}
    ok = {"2": [base], "3": [base | {"--withdrawn"}, base | {"--withdrawn", "--carry"}]}.get(opts.get("--schema"), [])
    if len(a[1:-2]) != 2 * len(opts) or set(opts) not in ok:
        sys.exit("usage")
    schema, env, stage = int(opts["--schema"]), a[-2], a[-1]
    doc = {"schema": schema, "serial": int(opts["--serial"]), "generated": opts["--generated"]}
    if schema == 3 and os.environ.get("FAKE_SKEW_GENERATED"):
        doc["generated"] = "2000-01-01T00:00:00Z"
    c = carried(opts["--carry"]) if "--carry" in opts else {}
    if schema == 3:
        doc["withdrawn"] = withdrawn(opts["--withdrawn"])
    doc["modules"] = []
    for m in modules(env):
        if schema == 2 and m["owner"] != "ReCasaOS":
            continue
        if is_carried(m, c):
            if os.path.exists(os.path.join(stage, m["name"])):
                sys.exit("error: module %s is carried and was staged" % m["name"])
            doc["modules"].append(c[m["name"]])
            continue
        if not os.path.exists(os.path.join(stage, m["name"], "checksums.txt")):
            sys.exit("error: module %s is not staged" % m["name"])
        doc["modules"].append(entry(m, schema, stage))
    open(opts["--out"], "w").write(json.dumps(doc, indent=2) + "\n")
elif a[:1] == ["proof"] and len(a) in (3, 5):
    schema = int(a[4]) if len(a) == 5 and a[3] == "--schema" else 3
    out = json.load(open(a[2]))
    if out["catalogue"]["ok"] is not True:
        sys.exit("error: the core does not take the catalogue")
    listed = {m["name"] for m in out["modules"]}
    for m in modules(a[1]):
        if (schema == 3 or m["owner"] == "ReCasaOS") and m["name"] not in listed:
            sys.exit("error: the core does not list module %s" % m["name"])
else:
    sys.exit("usage")
EOF
git -C "${inst}" update-index --add --chmod=+x scripts/stage-modules.sh 2>/dev/null || true
INST_GOOD="$(commit_all "${inst}" "fake installer")"
# main moves on far past the pinned commit (more than build.sh's first, shallow look at main)
for i in $(seq 60); do git -C "${inst}" -c user.name=test -c user.email=test@invalid commit -q --allow-empty -m "later ${i}"; done
# a commit that the repository serves only as a pull request's head, never merged into main
INST_PR="$(git -C "${inst}" -c user.name=test -c user.email=test@invalid commit-tree "${INST_GOOD}^{tree}" -p "${INST_GOOD}" -m "outside pull request")"
git -C "${inst}" update-ref refs/pull/7/head "${INST_PR}"

# --- the fake core: reads the online catalogue as the real one does ----------
core="${T}/core"
mkdir -p "${core}"
git -C "${core}" init -q -b main
git -C "${core}" config uploadpack.allowAnySHA1InWant true
printf 'module fakecore\n\ngo 1.22\n' >"${core}/go.mod"
cat >"${core}/main.go" <<'EOF'
package main

import (
	"encoding/json"
	"fmt"
	"os"
)

var refuse = false

// a catalogue of this schema is refused (0: none)
var refuseSchema = 0

// the marker build.sh looks for before it runs a core
var marker = "CASAOS_MODULE_RESULT"

func main() {
	if len(os.Args) != 3 || os.Args[1] != "module" || os.Args[2] != "list" || os.Getenv("CASAOS_MODULE_TEST") != "1" {
		fmt.Fprintln(os.Stderr, marker, "bad call")
		os.Exit(3)
	}
	if _, err := os.Stat(os.Getenv("CASAOS_MODULE_CATALOGUE")); err == nil {
		fmt.Fprintln(os.Stderr, "a shipped catalogue was given")
		os.Exit(3)
	}
	var cat struct {
		Schema  int              `json:"schema"`
		Serial  int64            `json:"serial"`
		Modules []map[string]any `json:"modules"`
	}
	raw, err := os.ReadFile(os.Getenv("CASAOS_MODULE_ONLINE_CATALOGUE"))
	if err == nil {
		err = json.Unmarshal(raw, &cat)
	}
	if refuse || err != nil || (refuseSchema != 0 && cat.Schema == refuseSchema) {
		fmt.Println(`{"catalogue":{"ok":false,"error":"invalid","online":{"ok":false,"error":"invalid"}},"modules":[]}`)
		return
	}
	for _, m := range cat.Modules {
		m["source"] = "online"
	}
	out, _ := json.Marshal(map[string]any{
		"catalogue": map[string]any{"ok": true, "online": map[string]any{"ok": true, "serial": cat.Serial}},
		"modules":   cat.Modules,
	})
	fmt.Println(string(out))
}
EOF
CORE_GOOD="$(commit_all "${core}" "fake core")"
sed -i 's/var refuseSchema = 0/var refuseSchema = 3/' "${core}/main.go"
CORE_REFUSES_3="$(commit_all "${core}" "fake core that refuses schema 3")"
sed -i -e 's/var refuseSchema = 3/var refuseSchema = 0/' -e 's/var refuse = false/var refuse = true/' "${core}/main.go"
CORE_REFUSES="$(commit_all "${core}" "fake core that refuses")"
sed -i -e 's/var refuse = true/var refuse = false/' -e 's/"serial": cat.Serial}/"serial": cat.Serial + 1}/' "${core}/main.go"
CORE_OTHER_SERIAL="$(commit_all "${core}" "fake core that reports another serial")"
# the same core in a repository that has no main
git clone -q --bare "${core}" "${T}/core-nomain"
git -C "${T}/core-nomain" branch -m main other
git -C "${T}/core-nomain" config uploadpack.allowAnySHA1InWant true

# --- the fake gh of the attestation: notes its arguments, fails when FAKE_GH_FAIL is set
cat >"${T}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${FAKE_GH_CALLS}"
printf -- '--\n' >>"${FAKE_GH_CALLS}"
if [[ -n "${FAKE_GH_FAIL:-}" || "$5" == "${FAKE_GH_FAIL_REPO:-}" ]]; then
    echo "no attestations found" >&2
    exit 1
fi
EOF
chmod +x "${T}/gh"

# --- a copy of this repository with its own refs.env ------------------------
repo="${T}/repo"
mkdir -p "${repo}/scripts"
cp "${ROOT}/scripts/build.sh" "${ROOT}/scripts/compare.py" "${ROOT}/scripts/names.py" "${ROOT}/scripts/license.py" "${ROOT}/scripts/attest.sh" "${ROOT}/scripts/unattested.sh" "${repo}/scripts/"
# the versions of the tests' modules.env that carry no attestation
printf '# test
virt v0.2.6
vuln-scan v0.1.3
mcp v0.2.1
' >"${repo}/unattested.txt"
# the list of the tests, not the one of the repository: that one grows with every module proposed
cp "${ROOT}/tests/fixtures/modules.env" "${repo}/modules.env"
cp "${ROOT}/retired.env" "${ROOT}/withdrawn.txt" "${repo}/"
cp "${ROOT}/tests/fixtures/modules.env" "${T}/base.env"

# make_files NAME TAG [LICENCE=1] [PAD_BYTES=0]: what the release of a module holds, in ${T}/files/NAME: checksums.txt and the two archives
make_files() {
    local name="$1" tag="$2" licence="${3:-1}" pad="${4:-0}" d="${T}/files/$1" w="${T}/tarwork/$1" arch
    local members=(module.json)
    rm -rf "${d}" "${w}"
    mkdir -p "${d}" "${w}"
    echo '{}' >"${w}/module.json"
    if [[ "${licence}" == 1 ]]; then echo "a licence" >"${w}/LICENSE"; members+=(LICENSE); fi
    if [[ "${pad}" != 0 ]]; then head -c "${pad}" /dev/urandom >"${w}/pad.bin"; members+=(pad.bin); fi
    for arch in amd64 arm64; do tar -czf "${d}/linux-${arch}-casaos-${name}-${tag}.tar.gz" -C "${w}" "${members[@]}"; done
    (cd "${d}" && sha256sum linux-*.tar.gz >checksums.txt)
}
while read -r name component tag _; do
    [[ -n "${name}" ]] && make_files "${name}" "${tag}"
done < <(python3 "${inst}/scripts/build-modules-catalogue.py" list "${repo}/modules.env")

add_alice() { # a module of another owner in modules.env
    cat >>"${repo}/modules.env" <<'EOF'
MODULE_ALICE_TOOL_TAG=v0.1.0
MODULE_ALICE_TOOL_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MODULE_ALICE_TOOL_COMPONENT=casaos-alice-tool
MODULE_ALICE_TOOL_TIER=community
MODULE_ALICE_TOOL_OWNER=alice
EOF
}

published="" # when set, build.sh is given it as PUBLISHED_DIR
run_build() { # run_build INSTALLER_COMMIT CORE_COMMIT SERIAL OUTDIR [VAR=value...]: output in ${T}/log, the gh calls in ${T}/calls; OUTDIR is removed first
    printf 'INSTALLER_COMMIT=%s\nCORE_COMMIT=%s\n' "$1" "$2" >"${repo}/refs.env"
    local serial="$3" out="$4"
    shift 4
    rm -rf "${out}"
    : >"${T}/calls"
    env MODULES_TEST_INSTALLER_DIR="${inst}" MODULES_TEST_CORE_DIR="${core}" FAKE_FILES="${T}/files" GH="${T}/gh" FAKE_GH_CALLS="${T}/calls" "$@" \
        bash "${repo}/scripts/build.sh" "${serial}" "${out}" ${published:+"${published}"} >"${T}/log" 2>&1
}

# 1. the happy path: both catalogues with the serial asked for, and the archives of each module to copy
out="${T}/out"
if run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" &&
    python3 - "${out}" "${T}/files" <<'EOF' &&
import hashlib, json, os, sys
d = sys.argv[1]
c2, c3 = (json.load(open(os.path.join(d, "catalogue-%d.json" % n))) for n in (2, 3))
assert c2["schema"] == 2 and c3["schema"] == 3 and c2["serial"] == c3["serial"] == 7 and c2["generated"] == c3["generated"], (c2, c3)
assert len(c2["modules"]) == 3 and len(c3["modules"]) == 3 and c3["withdrawn"] == [] and "withdrawn" not in c2, (c2, c3)
want = {"m-%s-%s" % (e["name"], e["tag"]) for e in c3["modules"]}
assert set(os.listdir(os.path.join(d, "mirror"))) == want and len(want) == 3, want
for e in c3["modules"]:
    folder = os.path.join(d, "mirror", "m-%s-%s" % (e["name"], e["tag"]))
    assert sorted(os.listdir(folder)) == sorted(["checksums.txt"] + [a["url"].rsplit("/", 1)[1] for a in e["assets"].values()]), os.listdir(folder)
    # the bytes: each archive is the one the catalogue digests, checksums.txt is the release's
    for a in e["assets"].values():
        assert hashlib.sha256(open(os.path.join(folder, a["url"].rsplit("/", 1)[1]), "rb").read()).hexdigest() == a["sha256"], a
    assert open(os.path.join(folder, "checksums.txt"), "rb").read() == open(os.path.join(sys.argv[2], e["name"], "checksums.txt"), "rb").read()
EOF
    grep -q "test only" "${T}/log" && grep -q "reads catalogue-2.json" "${T}/log" && grep -q "reads catalogue-3.json" "${T}/log" &&
    grep -q "OWNERS_BASE_URL=https://github.com CARRY_CATALOGUE=$" "${T}/log" && [[ ! -s "${T}/calls" ]]; then
    pass "the happy path writes both catalogues, the folder of each module to copy, and the core reads both"
else
    fail "the happy path writes both catalogues, the folder of each module to copy, and the core reads both"; cat "${T}/log"
fi
cp "${out}/catalogue-2.json" "${T}/built.json" 2>/dev/null

# 1b. the usage, and an OUTDIR that exists
bash "${repo}/scripts/build.sh" >"${T}/log" 2>&1
status=$?
if [[ "${status}" == 2 ]] && grep -q "usage: scripts/build.sh SERIAL OUTDIR \[PUBLISHED_DIR\]" "${T}/log"; then
    pass "no argument is a usage error (status 2)"
else
    fail "no argument is a usage error (status 2)"; cat "${T}/log"
fi
mkdir -p "${T}/exists"
if ! bash "${repo}/scripts/build.sh" 7 "${T}/exists" >"${T}/log" 2>&1 && grep -q "exists already" "${T}/log" && [[ -d "${T}/exists" ]]; then
    pass "an OUTDIR that exists is refused and left alone"
else
    fail "an OUTDIR that exists is refused and left alone"; cat "${T}/log"
fi

# 2. an archive that no longer matches its sum: the failure names the module, nothing at OUTDIR
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" FAKE_BAD_SUM=vuln-scan && grep -q "vuln-scan" "${T}/log" &&
    grep -q "^build.sh: The release files of the modules could not be fetched, or one does not match its checksums.txt" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a sum that no longer matches fails with build.sh's sentence (the stage folder never made), names the module, leaves no folder"
else
    fail "a sum that no longer matches fails with build.sh's sentence (the stage folder never made), names the module, leaves no folder"; cat "${T}/log"
fi
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" FAKE_STAGE_FAILS_LATE=1 &&
    grep -q "^build.sh: The release files of the modules could not be fetched, or one does not match its checksums.txt" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a stage step that fails with its folder made fails with build.sh's sentence"
else
    fail "a stage step that fails with its folder made fails with build.sh's sentence"; cat "${T}/log"
fi

# 3. the core refuses the catalogue: failure, nothing at OUTDIR
if ! run_build "${INST_GOOD}" "${CORE_REFUSES}" 7 "${out}" && grep -q "does not take the catalogue" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a core that refuses the catalogue fails and leaves no folder"
else
    fail "a core that refuses the catalogue fails and leaves no folder"; cat "${T}/log"
fi

# 3a. a core that takes the first file and refuses the second: the failure names the second
if ! run_build "${INST_GOOD}" "${CORE_REFUSES_3}" 7 "${out}" && grep -q "reads catalogue-2.json" "${T}/log" &&
    grep -q "does not take the catalogue catalogue-3.json" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a core that refuses catalogue-3.json fails, naming it, and leaves no folder"
else
    fail "a core that refuses catalogue-3.json fails, naming it, and leaves no folder"; cat "${T}/log"
fi

# 3b. a core that reports another serial fails, even with PYTHONOPTIMIZE in the environment
if ! run_build "${INST_GOOD}" "${CORE_OTHER_SERIAL}" 7 "${out}" PYTHONOPTIMIZE=1 &&
    grep -q "did not read the catalogue as its online catalogue at serial 7" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a core that reports another serial fails, with PYTHONOPTIMIZE=1 too"
else
    fail "a core that reports another serial fails, with PYTHONOPTIMIZE=1 too"; cat "${T}/log"
fi

# 3c. two files that do not have the same time are refused
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" FAKE_SKEW_GENERATED=1 && grep -q "^build.sh: The two catalogues do not have the same serial and the same time" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "two catalogues with another time fail, with no folder"
else
    fail "two catalogues with another time fail, with no folder"; cat "${T}/log"
fi

# 4. a commit in refs.env that is not 40 lower case hex digits is refused before any fetch
if ! run_build "${INST_GOOD^^}" "${CORE_GOOD}" 7 "${out}" && grep -q "INSTALLER_COMMIT" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a malformed commit in refs.env is refused"
else
    fail "a malformed commit in refs.env is refused"; cat "${T}/log"
fi

# 5. a pinned commit that the repository does not have is refused
if ! run_build "${INST_GOOD}" "0000000000000000000000000000000000000000" 7 "${out}" && grep -q "The core at 0* could not be fetched" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a pinned commit that cannot be fetched is refused"
else
    fail "a pinned commit that cannot be fetched is refused"; cat "${T}/log"
fi

# 6. a serial that is not a positive integer is refused
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 0 "${out}" && grep -qi "serial" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a serial of 0 is refused"
else
    fail "a serial of 0 is refused"; cat "${T}/log"
fi

# --- against the published catalogues (PUBLISHED_DIR) -----------------------
mutate() { # mutate PYTHON: ${T}/pub/catalogue-2.json is built.json after PYTHON ran on c, its modules by name in m
    published="${T}/pub"
    mkdir -p "${published}"
    python3 - "${T}/built.json" "${published}/catalogue-2.json" "$1" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
m = {e["name"]: e for e in c["modules"]}
exec(sys.argv[3])
json.dump(c, open(sys.argv[2], "w"))
EOF
}
refused() { # refused NAME PATTERN...: build.sh with ${published} fails, says each pattern, leaves no OUTDIR
    local name="$1" p ok=1
    shift
    run_build "${INST_GOOD}" "${CORE_GOOD}" 8 "${out}" && ok=0
    for p in "$@"; do grep -q -- "${p}" "${T}/log" || ok=0; done
    [[ ! -e "${out}" ]] || ok=0
    if [[ "${ok}" == 1 ]]; then pass "${name}"; else fail "${name}"; cat "${T}/log"; fi
}
accepted() { # accepted NAME: build.sh with ${published} passes
    if run_build "${INST_GOOD}" "${CORE_GOOD}" 8 "${out}" && [[ -s "${out}/catalogue-2.json" ]]; then pass "$1"; else fail "$1"; cat "${T}/log"; fi
}

mutate 'm["virt"]["assets"]["amd64"]["sha256"] = "0" * 64'
refused "same tag and commit, another amd64 sha256: fails naming the module" "virt" "amd64" "new tag"
mutate 'm["mcp"]["assets"]["arm64"]["url"] += ".old"'
refused "same tag and commit, another url: fails" "mcp" "arm64" "new tag"
mutate 'm["vuln-scan"]["manifest"]["title"] = "Old title"'
refused "same tag and commit, another manifest: fails" "vuln-scan" "manifest" "new tag"
mutate 'm["virt"]["tag"] = "v0.2.5"; m["virt"]["commit"] = "c" * 40; m["virt"]["assets"]["amd64"]["sha256"] = "1" * 64'
accepted "a higher tag with new digests passes (only catalogue-2.json published: schema 3 is not compared)"
mutate 'm["virt"]["tier"] = "community"'
accepted "a tier change alone passes"
mkdir -p "${T}/sd-old" "${T}/sd-new"
cp "${published}/catalogue-2.json" "${T}/sd-old/catalogue-2.json"
cp "${out}/catalogue-2.json" "${T}/sd-new/catalogue-2.json"
if python3 "${ROOT}/scripts/summary.py" "${T}/sd-old" "${T}/sd-new" | grep "virt" | grep -q "community.*core"; then
    pass "a tier change alone is in the summary"
else
    fail "a tier change alone is in the summary"
fi

mutate 'm["virt"]["tag"] = "v0.2.7"'
refused "a tag lower than the published one fails" "virt" "v0.2.6" "v0.2.7" "higher tag"
mutate 'm["virt"]["tag"] = "v0.2.06"'
refused "a tag equal to the published one but spelled otherwise fails" "virt" "v0.2.6" "v0.2.06"
mutate 'm["mcp"]["tag"] = "v0.9.0"'
cp "${published}/catalogue-2.json" "${T}/old-v09.json"
mutate 'm["mcp"]["tag"] = "v0.10.0"; m["mcp"]["assets"]["amd64"]["sha256"] = "2" * 64'
if python3 "${ROOT}/scripts/compare.py" "${T}/old-v09.json" "${published}/catalogue-2.json" >"${T}/log" 2>&1; then
    pass "v0.10.0 after v0.9.0 passes (numbers, not text)"
else
    fail "v0.10.0 after v0.9.0 passes (numbers, not text)"; cat "${T}/log"
fi

printf '<!DOCTYPE html><html><body>Not Found</body></html>\n' >"${published}/catalogue-2.json"
refused "a published file that is HTML fails" "not a schema 2 catalogue"
mutate 'c["schema"] = 1; del c["serial"], c["generated"]'
refused "a published file of schema 1 fails" "not a schema 2 catalogue"
mutate 'pass'
head -c 200 "${T}/built.json" >"${published}/catalogue-2.json"
refused "a truncated published file fails" "not a schema 2 catalogue"
published="${T}/pub-notafolder"
refused "a published folder that is not a folder fails" "is not a folder"
published=""

# --- the pins must be in the history of main -------------------------------
if run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" && [[ -s "${out}/catalogue-2.json" ]]; then
    pass "a pinned commit far behind main passes"
else
    fail "a pinned commit far behind main passes"; cat "${T}/log"
fi
if ! run_build "${INST_PR}" "${CORE_GOOD}" 7 "${out}" && grep -q "INSTALLER_COMMIT ${INST_PR} is not in the history of main" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a pinned commit only on refs/pull/7/head fails, naming the pin"
else
    fail "a pinned commit only on refs/pull/7/head fails, naming the pin"; cat "${T}/log"
fi
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" MODULES_TEST_CORE_DIR="${T}/core-nomain" && grep -q "main branch of the core" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a repository with no main fails"
else
    fail "a repository with no main fails"; cat "${T}/log"
fi

# an empty modules.env is refused before anything is fetched
grep '^#' "${T}/base.env" >"${repo}/modules.env"
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" MODULES_TEST_INSTALLER_DIR="${T}/nowhere" &&
    grep -q "modules.env lists no module" "${T}/log" && ! grep -q "could not be fetched" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "an empty modules.env is refused before any fetch"
else
    fail "an empty modules.env is refused before any fetch"; cat "${T}/log"
fi
cp "${T}/base.env" "${repo}/modules.env"

# --- a module of another owner ----------------------------------------------
add_alice
make_files alice-tool v0.1.0
# the first publication of schema 3: only catalogue-2.json is published
mkdir -p "${T}/pub2only"
cp "${T}/built.json" "${T}/pub2only/catalogue-2.json"
published="${T}/pub2only"
if run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" &&
    python3 - "${out}" <<'EOF' &&
import json, os, sys
d = sys.argv[1]
c2, c3 = (json.load(open(os.path.join(d, "catalogue-%d.json" % n))) for n in (2, 3))
assert "alice-tool" not in {e["name"] for e in c2["modules"]} and len(c2["modules"]) == 3, c2
e = {e["name"]: e for e in c3["modules"]}["alice-tool"]
assert len(c3["modules"]) == 4 and e["repository"] == "alice/casaos-alice-tool" and e["tier"] == "community", c3
assert sorted(os.listdir(os.path.join(d, "mirror"))) == sorted("m-%s-%s" % (m["name"], m["tag"]) for m in c3["modules"]), os.listdir(os.path.join(d, "mirror"))
assert sorted(os.listdir(os.path.join(d, "mirror", "m-alice-tool-v0.1.0"))) == ["checksums.txt", "linux-amd64-casaos-alice-tool-v0.1.0.tar.gz", "linux-arm64-casaos-alice-tool-v0.1.0.tar.gz"]
EOF
    grep -q "OWNERS_BASE_URL=https://github.com CARRY_CATALOGUE=$" "${T}/log"; then
    pass "a module of another owner is in catalogue-3.json, not in catalogue-2.json, with its folder to copy"
else
    fail "a module of another owner is in catalogue-3.json, not in catalogue-2.json, with its folder to copy"; cat "${T}/log"
fi
# its two archives were verified, by the owner's repository at its pinned tag and commit, and nothing else was
if [[ "$(grep -c '^--$' "${T}/calls")" == 2 ]] && grep -qx 'alice/casaos-alice-tool' "${T}/calls" && grep -qx 'refs/tags/v0.1.0' "${T}/calls" &&
    grep -qx 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${T}/calls" && ! grep -q 'virt' "${T}/calls"; then
    pass "gh verifies the two archives of the module of another owner, and none of ours"
else
    fail "gh verifies the two archives of the module of another owner, and none of ours"; cat "${T}/calls"
fi
# what is published after it: both files
mkdir -p "${T}/pub3"
cp "${out}/catalogue-2.json" "${out}/catalogue-3.json" "${T}/pub3/"

if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" FAKE_GH_FAIL=1 && grep -q "alice/casaos-alice-tool" "${T}/log" && grep -q "alice-tool" "${T}/log" &&
    grep -q "provenance of .* is not established" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "an attestation that is refused fails, naming the module and its repository, with no folder"
else
    fail "an attestation that is refused fails, naming the module and its repository, with no folder"; cat "${T}/log"
fi

# our own modules are verified too, except the versions of unattested.txt
cp "${repo}/unattested.txt" "${T}/unattested.full"
grep -v '^virt ' "${T}/unattested.full" >"${repo}/unattested.txt"
if run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" && [[ "$(grep -c '^--$' "${T}/calls")" == 4 ]] &&
    grep -qx 'ReCasaOS/CasaOS-VirtManagement' "${T}/calls" && ! grep -q 'ReCasaOS-VulnScan\|ReCasaOS-MCP' "${T}/calls"; then
    pass "our module that is not in unattested.txt is verified (both archives), the ones listed are not"
else
    fail "our module that is not in unattested.txt is verified (both archives), the ones listed are not"; cat "${T}/log" "${T}/calls"
fi
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" FAKE_GH_FAIL_REPO=ReCasaOS/CasaOS-VirtManagement && grep -q "Module virt: the provenance" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "our module with no attestation and not in unattested.txt fails the build, with no folder"
else
    fail "our module with no attestation and not in unattested.txt fails the build, with no folder"; cat "${T}/log"
fi
cp "${T}/unattested.full" "${repo}/unattested.txt"
if run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" FAKE_GH_FAIL_REPO=ReCasaOS/CasaOS-VirtManagement; then
    pass "our module with no attestation, listed in unattested.txt, builds"
else
    fail "our module with no attestation, listed in unattested.txt, builds"; cat "${T}/log"
fi
echo "alice-tool v0.1.0" >>"${repo}/unattested.txt"
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" && grep -q "only a module of ReCasaOS can be exempt" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a module of another owner listed in unattested.txt is refused"
else
    fail "a module of another owner listed in unattested.txt is refused"; cat "${T}/log"
fi
cp "${T}/unattested.full" "${repo}/unattested.txt"

make_files alice-tool v0.1.0 0
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" && grep -q "alice-tool" "${T}/log" && grep -q "has no LICENSE at its root" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "an archive without a LICENSE fails, naming the module, with no folder"
else
    fail "an archive without a LICENSE fails, naming the module, with no folder"; cat "${T}/log"
fi

make_files alice-tool v0.1.0 1 4096
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" MODULES_TEST_MAX_FILE_KIB=2 && grep -q "test only: a downloaded file is bounded to 2 KiB" "${T}/log" &&
    grep -q "an archive is larger than 2 KiB" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "an archive over the bound stops the download with a sentence, with no folder"
else
    fail "an archive over the bound stops the download with a sentence, with no folder"; cat "${T}/log"
fi
if run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" MODULES_TEST_MAX_FILE_KIB=64 && [[ -s "${out}/catalogue-3.json" ]]; then
    pass "the same archive under the bound passes"
else
    fail "the same archive under the bound passes"; cat "${T}/log"
fi
make_files alice-tool v0.1.0
# a checksums.txt over the bound is a file, not an archive
make_files alice-tool v0.1.0
head -c 2000 /dev/zero | tr ' ' x >>"${T}/files/alice-tool/checksums.txt"
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" MODULES_TEST_MAX_FILE_KIB=1 && grep -q "a downloaded file is larger than 1 KiB (alice-tool/checksums.txt)" "${T}/log" &&
    ! grep -q "an archive is larger" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a checksums.txt over the bound is called a file, not an archive"
else
    fail "a checksums.txt over the bound is called a file, not an archive"; cat "${T}/log"
fi
make_files alice-tool v0.1.0

# a name retired
printf 'alice-tool casaos-alice-tool.service -\n' >>"${repo}/retired.env"
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" && grep -q "Module alice-tool: the name belongs to a retired module" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a retired name that is taken again fails, naming it, with no folder"
else
    fail "a retired name that is taken again fails, naming it, with no folder"; cat "${T}/log"
fi
cp "${ROOT}/retired.env" "${repo}/retired.env"

# a withdrawn version
printf '# test\nvirt v0.2.5 a release with a bug\n' >"${repo}/withdrawn.txt"
if run_build "${INST_GOOD}" "${CORE_GOOD}" 9 "${out}" &&
    python3 - "${out}" <<'EOF'; then
import json, os, sys
c2, c3 = (json.load(open(os.path.join(sys.argv[1], "catalogue-%d.json" % n))) for n in (2, 3))
assert c3["withdrawn"] == [{"name": "virt", "tag": "v0.2.5", "reason": "a release with a bug"}] and "withdrawn" not in c2, c3
EOF
    pass "a line of withdrawn.txt is in catalogue-3.json"
else
    fail "a line of withdrawn.txt is in catalogue-3.json"; cat "${T}/log"
fi
cp "${ROOT}/withdrawn.txt" "${repo}/withdrawn.txt"

# the module of another owner is published now, and its repository is gone: it is built again, carried, and nothing of it is fetched or copied
rm -rf "${T}/files/alice-tool"
published="${T}/pub3"
if run_build "${INST_GOOD}" "${CORE_GOOD}" 10 "${out}" &&
    python3 - "${out}" "${T}/pub3/catalogue-3.json" <<'EOF' &&
import json, os, sys
d, published = sys.argv[1:]
c3 = json.load(open(os.path.join(d, "catalogue-3.json")))
before = {e["name"]: e for e in json.load(open(published))["modules"]}
now = {e["name"]: e for e in c3["modules"]}
assert now["alice-tool"] == before["alice-tool"] and c3["serial"] == 10, c3
assert sorted(os.listdir(os.path.join(d, "mirror"))) == sorted("m-%s-%s" % (e["name"], e["tag"]) for e in c3["modules"] if e["name"] != "alice-tool"), os.listdir(os.path.join(d, "mirror"))
EOF
    grep -q "CARRY_CATALOGUE=${T}/pub3/catalogue-3.json" "${T}/log" && [[ ! -s "${T}/calls" ]]; then
    pass "a module of another owner already published is carried when its repository is gone: no mirror folder, no verification"
else
    fail "a module of another owner already published is carried when its repository is gone: no mirror folder, no verification"; cat "${T}/log"
fi

# a published catalogue-3.json that another sha256 or another repository contradicts, for a tag it already holds
for change in 'e["assets"]["amd64"]["sha256"] = "0" * 64' 'e["repository"] = "mallory/CasaOS-VirtManagement"'; do
    mkdir -p "${T}/pub3m"
    python3 - "${T}/pub3/catalogue-3.json" "${T}/pub3m/catalogue-3.json" "${change}" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
e = {e["name"]: e for e in c["modules"]}["virt"]
exec(sys.argv[3])
json.dump(c, open(sys.argv[2], "w"))
EOF
    published="${T}/pub3m"
    if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 10 "${out}" && grep -q "^build.sh: The catalogue of schema 3 changes a module under a tag that is already published" "${T}/log" &&
        grep -q "virt" "${T}/log" && [[ ! -e "${out}" ]]; then
        pass "a module that changes under a published tag in catalogue-3.json fails (${change%% =*})"
    else
        fail "a module that changes under a published tag in catalogue-3.json fails (${change%% =*})"; cat "${T}/log"
    fi
done
published="${T}/pub3"

# a published module that is not listed any more, with no line in retired.env, is refused (names.py is given the published catalogue-3.json)
cp "${T}/base.env" "${repo}/modules.env"
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 10 "${out}" && grep -q "alice-tool" "${T}/log" && grep -q "retired.env" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a module taken out of modules.env with no line in retired.env fails, naming it"
else
    fail "a module taken out of modules.env with no line in retired.env fails, naming it"; cat "${T}/log"
fi
published=""

# --- summary.py -------------------------------------------------------------
cat_of() { # cat_of DIR SERIAL name:tag:tier...: DIR/catalogue-2.json
    local file="$1/catalogue-2.json" serial="$2"
    mkdir -p "$1"
    shift 2
    python3 - "${file}" "${serial}" "$@" <<'EOF'
import json, sys
mods = [dict(zip(("name", "tag", "tier"), m.split(":")), component="c", commit="a" * 40, manifest={},
             assets={a: {"url": "https://example.invalid/x", "sha256": "b" * 64} for a in ("amd64", "arm64")}) for m in sys.argv[3:]]
json.dump({"schema": 2, "serial": int(sys.argv[2]), "generated": "2026-11-25T12:00:00Z", "modules": mods}, open(sys.argv[1], "w"))
EOF
}
summary() { python3 "${ROOT}/scripts/summary.py" "$@" >"${T}/sum" 2>&1; }

cat_of "${T}/old" 3 virt:v0.2.5:core mcp:v0.2.0:core
cat_of "${T}/new" 4 virt:v0.2.6:core
if summary "${T}/old" "${T}/new" && grep -q "v0.2.5" "${T}/sum" && grep -q "v0.2.6" "${T}/sum"; then
    pass "summary: a tag that goes up shows before and after"
else
    fail "summary: a tag that goes up shows before and after"; cat "${T}/sum"
fi
if grep "mcp" "${T}/sum" | grep -q "removed"; then
    pass "summary: a removed module says removed"
else
    fail "summary: a removed module says removed"; cat "${T}/sum"
fi

if summary "${T}/missing" "${T}/new" && grep -q "first publication" "${T}/sum" && grep "virt" "${T}/sum" | grep -q "added"; then
    pass "summary: no old catalogue is the first publication"
else
    fail "summary: no old catalogue is the first publication"; cat "${T}/sum"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL: ${failures} test(s)"
    exit 1
fi
