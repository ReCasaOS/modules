#!/usr/bin/env bash
#
# Builds the online catalogue of the modules from modules.env, and proves that
# the core reads it:
#
#   scripts/build.sh SERIAL OUT
#
# 1. fetches ReCasaOS/CasaOS-Install at INSTALLER_COMMIT and ReCasaOS/CasaOS at
#    CORE_COMMIT (refs.env), each into a fresh folder, never by a branch name;
# 2. runs the installer's scripts/stage-modules.sh, which downloads each
#    module's checksums.txt and archives and checks each sum;
# 3. runs its scripts/build-modules-catalogue.py build --schema 2, which judges
#    every module and writes the catalogue with SERIAL and the time now (UTC);
# 4. builds the core and runs its `casaos module list` on that file as the
#    online catalogue, with no shipped one; build-modules-catalogue.py proof
#    judges what it printed, and the core must say it read this file online.
#
# OUT is written only when all of that holds. On any failure: a non-zero exit,
# one sentence naming the check that failed, and no file at OUT.
#
# Needs bash, git, curl, python3 (3.12: see build-modules-catalogue.py), go and
# timeout. Refuses to run as root: it runs the core it builds.
#
# For the tests only (tests/test-build.sh), each said on the output when set:
#   MODULES_TEST_INSTALLER_DIR  a local git repository fetched instead of CasaOS-Install
#   MODULES_TEST_CORE_DIR       a local git repository fetched instead of CasaOS

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly GITHUB_BASE="https://github.com/ReCasaOS"
readonly PYTHON=python3
readonly PROBE_TIMEOUT=30

fail() {
    echo "build.sh: $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || { echo "usage: scripts/build.sh SERIAL OUT" >&2; exit 2; }
serial="$1"
out="$2"
rm -f "${out}"

[[ "$(id -u)" != 0 ]] || fail "Refused to run as root: this runs the core it builds."
[[ "${serial}" =~ ^[1-9][0-9]{0,17}$ ]] || fail "The serial '${serial}' is not a positive integer."

# refs.env is read, never sourced: exactly the two lines, each a full commit
refs="$(cat "${ROOT}/refs.env")" || fail "refs.env cannot be read."
[[ "${refs}" =~ ^INSTALLER_COMMIT=([0-9a-f]{40})$'\n'CORE_COMMIT=([0-9a-f]{40})$ ]] ||
    fail "refs.env must be the two lines INSTALLER_COMMIT=<40 lower case hex> and CORE_COMMIT=<40 lower case hex>, and nothing else."
installer_commit="${BASH_REMATCH[1]}"
core_commit="${BASH_REMATCH[2]}"

installer_url="${GITHUB_BASE}/CasaOS-Install"
core_url="${GITHUB_BASE}/CasaOS"
if [[ -n "${MODULES_TEST_INSTALLER_DIR:-}" ]]; then
    installer_url="file://${MODULES_TEST_INSTALLER_DIR}"
    echo "build.sh: test only: the installer is fetched from ${installer_url} (MODULES_TEST_INSTALLER_DIR), not from GitHub."
fi
if [[ -n "${MODULES_TEST_CORE_DIR:-}" ]]; then
    core_url="file://${MODULES_TEST_CORE_DIR}"
    echo "build.sh: test only: the core is fetched from ${core_url} (MODULES_TEST_CORE_DIR), not from GitHub."
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# fetch DIR URL COMMIT WHAT: a shallow fetch of exactly that commit
fetch() {
    local dir="$1" url="$2" commit="$3" what="$4"
    git init -q "${dir}" &&
        git -C "${dir}" fetch -q --depth 1 "${url}" "${commit}" &&
        git -C "${dir}" -c advice.detachedHead=false checkout -q FETCH_HEAD ||
        fail "The ${what} at ${commit} could not be fetched from ${url}."
    [[ "$(git -C "${dir}" rev-parse HEAD)" == "${commit}" ]] || fail "The ${what} fetched from ${url} is not at ${commit}."
}

fetch "${work}/installer" "${installer_url}" "${installer_commit}" installer
fetch "${work}/core" "${core_url}" "${core_commit}" core
installer="${work}/installer/scripts"

env CHECKSUMS_BASE_URL="${GITHUB_BASE}" PYTHON="${PYTHON}" bash "${installer}/stage-modules.sh" "${ROOT}/modules.env" "${work}/stage" ||
    fail "The release files of the modules could not be fetched, or one does not match its checksums.txt (see above)."

"${PYTHON}" "${installer}/build-modules-catalogue.py" build --git-base "${GITHUB_BASE}" --out "${work}/catalogue-2.json" \
    --schema 2 --serial "${serial}" --generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ROOT}/modules.env" "${work}/stage" ||
    fail "The catalogue was not built: a module does not hold (see above)."

# --- the proof: the core at CORE_COMMIT reads the file as its online catalogue
proof="${work}/proof"
mkdir -p "${proof}"
(
    cd "${work}/core" &&
        # the API code of the core is generated, and git does not hold it
        env -u GOOS -u GOARCH -u GOARM go generate &&
        env -u GOOS -u GOARCH -u GOARM CGO_ENABLED=0 \
            go build -buildvcs=false -trimpath -tags "musl netgo osusergo" -o "${proof}/casaos" .
) || fail "The core at ${core_commit} could not be built."

# an old core given 'module' starts as a second server and never ends: run only one that has the assistant
grep -aq 'CASAOS_MODULE_RESULT' "${proof}/casaos" ||
    fail "The core at ${core_commit} has no module assistant (no CASAOS_MODULE_RESULT in it); it was not run."

cp "${work}/catalogue-2.json" "${proof}/catalogue-2.json"
status=0
(
    ulimit -f 2048 2>/dev/null || true
    cd "${proof}"
    # CASAOS_MODULE_CATALOGUE names a file that does not exist: no shipped catalogue, only the online one
    exec timeout -k 5 "${PROBE_TIMEOUT}" env -i PATH="${PATH}" HOME="${proof}" CASAOS_MODULE_TEST=1 \
        CASAOS_MODULE_CATALOGUE="${proof}/no-shipped-catalogue.json" CASAOS_MODULE_ONLINE_CATALOGUE="${proof}/catalogue-2.json" \
        "${proof}/casaos" module list </dev/null >"${proof}/out" 2>"${proof}/err"
) || status=$?
case "${status}" in
0) ;;
124 | 137) fail "The core at ${core_commit} did not answer 'casaos module list' within ${PROBE_TIMEOUT} seconds and was killed." ;;
*) fail "The core at ${core_commit} failed 'casaos module list' with status ${status}: $(head -c 300 "${proof}/err" | tr -c '[:print:]\n' '?')" ;;
esac

"${PYTHON}" "${installer}/build-modules-catalogue.py" proof "${ROOT}/modules.env" "${proof}/out" ||
    fail "The core at ${core_commit} does not take the catalogue, or does not list its modules (see above)."

# proof does not tell the online file from a shipped one: the core must say it read this one, at this serial
"${PYTHON}" - "${proof}/out" "${serial}" <<'EOF' || fail "The core at ${core_commit} did not read the catalogue as its online catalogue at serial ${serial}."
import json, sys
out = json.load(open(sys.argv[1]))
online = out["catalogue"].get("online") or {}
assert online.get("ok") is True and online.get("serial") == int(sys.argv[2]), online
assert all(m.get("source") == "online" for m in out["modules"]), out["modules"]
EOF

mkdir -p "$(dirname "${out}")"
mv "${work}/catalogue-2.json" "${out}" || fail "The catalogue could not be written to ${out}."
echo "build.sh: built ${out} (serial ${serial}); the core at ${core_commit} reads it and lists its modules."
