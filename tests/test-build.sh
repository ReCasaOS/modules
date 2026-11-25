#!/usr/bin/env bash
# Offline tests of scripts/build.sh and scripts/summary.py. No network: the
# installer and the core are small fake git repositories made here, handed to
# build.sh through its two test-only variables. Needs bash, git, python3 and go.
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
# fake: FAKE_BAD_SUM=<module> says what the real one says when an archive does not match
set -euo pipefail
if [[ -n "${FAKE_BAD_SUM:-}" ]]; then
    echo "Module ${FAKE_BAD_SUM}: linux-amd64-casaos-${FAKE_BAD_SUM}-v0.0.1.tar.gz is not the archive that checksums.txt names." >&2
    exit 1
fi
mkdir -p "$2"
EOF
cat >"${inst}/scripts/build-modules-catalogue.py" <<'EOF'
#!/usr/bin/env python3
# fake: build writes a schema 2 catalogue of modules.env, with made-up digests; proof reads the core's answer
import hashlib, json, re, sys

def modules(path):
    found = {}
    for line in open(path):
        m = re.fullmatch(r"MODULE_([A-Z0-9_]+)_(TAG|COMMIT|COMPONENT|TIER)=(\S+)\n?", line)
        if m:
            found.setdefault(m[1].lower().replace("_", "-"), {})[m[2].lower()] = m[3]
    return [dict(name=n, **v) for n, v in sorted(found.items())]

def entry(m):
    url = "https://github.com/ReCasaOS/%s/releases/download/%s/linux-%%s-casaos-%s-%s.tar.gz" % (m["component"], m["tag"], m["name"], m["tag"])
    assets = {arch: {"url": url % arch, "sha256": hashlib.sha256((m["name"] + m["tag"] + arch).encode()).hexdigest()} for arch in ("amd64", "arm64")}
    return dict(m, assets=assets, manifest={"name": m["name"], "title": m["name"]})

a = sys.argv[1:]
if len(a) == 13 and a[0] == "build" and a[1] == "--git-base" and a[3] == "--out" and a[5:11:2] == ["--schema", "--serial", "--generated"]:
    doc = {"schema": int(a[6]), "serial": int(a[8]), "generated": a[10], "modules": [entry(m) for m in modules(a[11])]}
    open(a[4], "w").write(json.dumps(doc, indent=2) + "\n")
elif len(a) == 3 and a[0] == "proof":
    out = json.load(open(a[2]))
    if out["catalogue"]["ok"] is not True:
        sys.exit("error: the core does not take the catalogue")
    listed = {m["name"] for m in out["modules"]}
    for m in modules(a[1]):
        if m["name"] not in listed:
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
		Serial  int64            `json:"serial"`
		Modules []map[string]any `json:"modules"`
	}
	raw, err := os.ReadFile(os.Getenv("CASAOS_MODULE_ONLINE_CATALOGUE"))
	if err == nil {
		err = json.Unmarshal(raw, &cat)
	}
	if refuse || err != nil {
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
sed -i 's/var refuse = false/var refuse = true/' "${core}/main.go"
CORE_REFUSES="$(commit_all "${core}" "fake core that refuses")"
# the same core in a repository that has no main
git clone -q --bare "${core}" "${T}/core-nomain"
git -C "${T}/core-nomain" branch -m main other
git -C "${T}/core-nomain" config uploadpack.allowAnySHA1InWant true

# --- a copy of this repository with its own refs.env ------------------------
repo="${T}/repo"
mkdir -p "${repo}/scripts"
cp "${ROOT}/scripts/build.sh" "${ROOT}/scripts/compare.py" "${repo}/scripts/" 2>/dev/null
cp "${ROOT}/modules.env" "${repo}/modules.env"

published="" # when set, build.sh is given it as PUBLISHED
run_build() { # run_build INSTALLER_COMMIT CORE_COMMIT SERIAL OUT [VAR=value...]: output in ${T}/log
    printf 'INSTALLER_COMMIT=%s\nCORE_COMMIT=%s\n' "$1" "$2" >"${repo}/refs.env"
    local serial="$3" out="$4"
    shift 4
    env MODULES_TEST_INSTALLER_DIR="${inst}" MODULES_TEST_CORE_DIR="${core}" "$@" \
        bash "${repo}/scripts/build.sh" "${serial}" "${out}" ${published:+"${published}"} >"${T}/log" 2>&1
}

# 1. the happy path writes a schema 2 catalogue with the serial asked for
out="${T}/out/catalogue-2.json"
mkdir -p "${T}/out"
if run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" &&
    python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["schema"] == 2 and c["serial"] == 7 and len(c["modules"]) == 3, c' "${out}" &&
    grep -q "test only" "${T}/log"; then
    pass "the happy path writes a schema 2 catalogue with the serial asked for"
else
    fail "the happy path writes a schema 2 catalogue with the serial asked for"; cat "${T}/log"
fi
cp "${out}" "${T}/built.json" 2>/dev/null

# 2. an archive that no longer matches its sum: the failure names the module, nothing at OUT
echo stale >"${out}"
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" FAKE_BAD_SUM=vuln-scan && grep -q "vuln-scan" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a sum that no longer matches fails, names the module, leaves no file"
else
    fail "a sum that no longer matches fails, names the module, leaves no file"; cat "${T}/log"
fi

# 3. the core refuses the catalogue: failure, nothing at OUT
echo stale >"${out}"
if ! run_build "${INST_GOOD}" "${CORE_REFUSES}" 7 "${out}" && grep -q "does not take the catalogue" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a core that refuses the catalogue fails and leaves no file"
else
    fail "a core that refuses the catalogue fails and leaves no file"; cat "${T}/log"
fi

# 4. a commit in refs.env that is not 40 lower case hex digits is refused before any fetch
echo stale >"${out}"
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

# --- against the published catalogue (PUBLISHED) ----------------------------
mutate() { # mutate PYTHON: ${T}/published.json is built.json after PYTHON ran on c, its modules by name in m
    published="${T}/published.json"
    python3 - "${T}/built.json" "${published}" "$1" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
m = {e["name"]: e for e in c["modules"]}
exec(sys.argv[3])
json.dump(c, open(sys.argv[2], "w"))
EOF
}
refused() { # refused NAME PATTERN...: build.sh with ${published} fails, says each pattern, leaves no OUT
    local name="$1" p ok=1
    shift
    echo stale >"${out}"
    run_build "${INST_GOOD}" "${CORE_GOOD}" 8 "${out}" && ok=0
    for p in "$@"; do grep -q -- "${p}" "${T}/log" || ok=0; done
    [[ ! -e "${out}" ]] || ok=0
    if [[ "${ok}" == 1 ]]; then pass "${name}"; else fail "${name}"; cat "${T}/log"; fi
}
accepted() { # accepted NAME: build.sh with ${published} passes
    if run_build "${INST_GOOD}" "${CORE_GOOD}" 8 "${out}" && [[ -s "${out}" ]]; then pass "$1"; else fail "$1"; cat "${T}/log"; fi
}

mutate 'm["virt"]["assets"]["amd64"]["sha256"] = "0" * 64'
refused "same tag and commit, another amd64 sha256: fails naming the module" "virt" "amd64" "new tag"
mutate 'm["mcp"]["assets"]["arm64"]["url"] += ".old"'
refused "same tag and commit, another url: fails" "mcp" "arm64" "new tag"
mutate 'm["vuln-scan"]["manifest"]["title"] = "Old title"'
refused "same tag and commit, another manifest: fails" "vuln-scan" "manifest" "new tag"
mutate 'm["virt"]["tag"] = "v0.2.5"; m["virt"]["commit"] = "c" * 40; m["virt"]["assets"]["amd64"]["sha256"] = "1" * 64'
accepted "a higher tag with new digests passes"
mutate 'm["virt"]["tier"] = "community"'
accepted "a tier change alone passes"
if python3 "${ROOT}/scripts/summary.py" "${published}" "${out}" | grep "virt" | grep -q "community.*core"; then
    pass "a tier change alone is in the summary"
else
    fail "a tier change alone is in the summary"
fi

mutate 'm["virt"]["tag"] = "v0.2.7"'
refused "a tag lower than the published one fails" "virt" "v0.2.6" "v0.2.7" "higher tag"
mutate 'm["virt"]["tag"] = "v0.2.06"'
refused "a tag equal to the published one but spelled otherwise fails" "virt" "v0.2.6" "v0.2.06"
mutate 'm["mcp"]["tag"] = "v0.9.0"'
cp "${published}" "${T}/old-v09.json"
mutate 'm["mcp"]["tag"] = "v0.10.0"; m["mcp"]["assets"]["amd64"]["sha256"] = "2" * 64'
if python3 "${ROOT}/scripts/compare.py" "${T}/old-v09.json" "${published}" >"${T}/log" 2>&1; then
    pass "v0.10.0 after v0.9.0 passes (numbers, not text)"
else
    fail "v0.10.0 after v0.9.0 passes (numbers, not text)"; cat "${T}/log"
fi

printf '<!DOCTYPE html><html><body>Not Found</body></html>\n' >"${T}/published.json"
refused "a published file that is HTML fails" "not a schema 2 catalogue"
mutate 'c["schema"] = 1; del c["serial"], c["generated"]'
refused "a published file of schema 1 fails" "not a schema 2 catalogue"
mutate 'pass'
head -c 200 "${T}/built.json" >"${T}/published.json"
refused "a truncated published file fails" "not a schema 2 catalogue"
published=""

# --- the pins must be in the history of main -------------------------------
echo stale >"${out}"
if run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" && [[ -s "${out}" ]]; then
    pass "a pinned commit far behind main passes"
else
    fail "a pinned commit far behind main passes"; cat "${T}/log"
fi
echo stale >"${out}"
if ! run_build "${INST_PR}" "${CORE_GOOD}" 7 "${out}" && grep -q "INSTALLER_COMMIT ${INST_PR} is not in the history of main" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a pinned commit only on refs/pull/7/head fails, naming the pin"
else
    fail "a pinned commit only on refs/pull/7/head fails, naming the pin"; cat "${T}/log"
fi
echo stale >"${out}"
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" MODULES_TEST_CORE_DIR="${T}/core-nomain" && grep -q "main branch of the core" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "a repository with no main fails"
else
    fail "a repository with no main fails"; cat "${T}/log"
fi

# an empty modules.env is refused before anything is fetched
cp "${repo}/modules.env" "${T}/modules.env.keep"
grep '^#' "${T}/modules.env.keep" >"${repo}/modules.env"
echo stale >"${out}"
if ! run_build "${INST_GOOD}" "${CORE_GOOD}" 7 "${out}" MODULES_TEST_INSTALLER_DIR="${T}/nowhere" &&
    grep -q "modules.env lists no module" "${T}/log" && ! grep -q "could not be fetched" "${T}/log" && [[ ! -e "${out}" ]]; then
    pass "an empty modules.env is refused before any fetch"
else
    fail "an empty modules.env is refused before any fetch"; cat "${T}/log"
fi
cp "${T}/modules.env.keep" "${repo}/modules.env"

# --- summary.py -------------------------------------------------------------
cat_of() { # cat_of FILE SERIAL name:tag:tier...
    local file="$1" serial="$2"
    shift 2
    python3 - "${file}" "${serial}" "$@" <<'EOF'
import json, sys
mods = [dict(zip(("name", "tag", "tier"), m.split(":"))) for m in sys.argv[3:]]
json.dump({"schema": 2, "serial": int(sys.argv[2]), "generated": "2026-11-25T12:00:00Z", "modules": mods}, open(sys.argv[1], "w"))
EOF
}
summary() { python3 "${ROOT}/scripts/summary.py" "$@" >"${T}/sum" 2>&1; }

cat_of "${T}/old.json" 3 virt:v0.2.5:core mcp:v0.2.0:core
cat_of "${T}/new.json" 4 virt:v0.2.6:core
if summary "${T}/old.json" "${T}/new.json" && grep -q "v0.2.5" "${T}/sum" && grep -q "v0.2.6" "${T}/sum"; then
    pass "summary: a tag that goes up shows before and after"
else
    fail "summary: a tag that goes up shows before and after"; cat "${T}/sum"
fi
if grep "mcp" "${T}/sum" | grep -q "removed"; then
    pass "summary: a removed module says removed"
else
    fail "summary: a removed module says removed"; cat "${T}/sum"
fi

if summary "${T}/missing.json" "${T}/new.json" && grep -q "first publication" "${T}/sum" && grep "virt" "${T}/sum" | grep -q "added"; then
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
