#!/usr/bin/env bash
#
# Builds the two online catalogues of the modules from modules.env, proves that
# the core reads each, and gathers the archives to copy into this repository's
# own releases:
#
#   scripts/build.sh SERIAL OUTDIR [PUBLISHED_DIR]
#
# OUTDIR must not exist; on success it holds
#
#   catalogue-2.json   today's format (the modules of ReCasaOS only)
#   catalogue-3.json   schema 3: schema 2 plus the withdrawn versions (withdrawn.txt)
#                      and the modules of other owners, every archive at its mirror
#   mirror/m-<name>-<tag>/   the two archives and checksums.txt of each module that
#                      was fetched now, under their original names: the release of
#                      this repository that every box downloads from
#
# In this order:
# 1. fetches ReCasaOS/CasaOS-Install at INSTALLER_COMMIT and ReCasaOS/CasaOS at
#    CORE_COMMIT (refs.env), each into a fresh folder, never by a branch name,
#    and requires each commit to be in the history of that repository's main;
# 2. runs the installer's scripts/stage-modules.sh, which downloads each
#    module's checksums.txt and archives and checks each sum (the archives of
#    another owner also against the sums that modules.env pins), under a bound of
#    200 MiB on the size of any file it writes: a larger archive stops the build;
# 3. runs its scripts/build-modules-catalogue.py build, once for schema 2 and once
#    for schema 3 with withdrawn.txt, with the same serial SERIAL and the same time
#    now (UTC);
# 4. for each module that was fetched now, collects its files for mirror/;
#    scripts/attest.sh checks the provenance of both archives (not of the versions
#    that unattested.txt lists, ReCasaOS only), and for an owner other than
#    ReCasaOS scripts/license.py that each carries a LICENSE;
# 5. with PUBLISHED_DIR, the folder that scripts/published.sh filled, checks each
#    new file against the published one of the same name (scripts/compare.py): a
#    module at a tag already published must keep its commit, archives and
#    manifest; and scripts/names.py keeps retired names, units and routes;
# 6. builds the core and runs its `casaos module list` on each file in turn as the
#    online catalogue, with no shipped one; build-modules-catalogue.py proof
#    judges what it printed, and the core must say it read this file online, at
#    SERIAL; both files must have the same serial and the same time.
#
# PUBLISHED_DIR must be the catalogue that this repository published: its
# catalogue-3.json, when it has one, is also what the installer's scripts carry
# over (CARRY_CATALOGUE and --carry): a module of another owner that it already
# offers at the pinned tag is built from that entry and its archives are not
# fetched again, so the author's repository need not exist any more. With only a
# catalogue-2.json (the first publication of schema 3), schema 2 is compared and
# nothing is carried.
#
# modules.env must list at least one module: a catalogue with no module is not
# published.
#
# OUTDIR is written only when all of that holds. On any failure: a non-zero exit,
# one sentence naming the check that failed, and no OUTDIR.
#
# Needs bash, git, curl, python3 (3.12: see build-modules-catalogue.py), go and
# timeout. Refuses to run as root: it runs the core it builds. GH names the gh that
# scripts/attest.sh runs.
#
# For the tests only (tests/test-build.sh), each said on the output when set:
#   MODULES_TEST_INSTALLER_DIR  a local git repository fetched instead of CasaOS-Install
#   MODULES_TEST_CORE_DIR       a local git repository fetched instead of CasaOS
#   MODULES_TEST_MAX_FILE_KIB   the bound on the size of a downloaded file, in KiB, instead of 200 MiB

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly GITHUB_BASE="https://github.com/ReCasaOS"
readonly PYTHON=python3
readonly PROBE_TIMEOUT=30

fail() {
    echo "build.sh: $*" >&2
    exit 1
}

[[ $# -eq 2 || $# -eq 3 ]] || { echo "usage: scripts/build.sh SERIAL OUTDIR [PUBLISHED_DIR]" >&2; exit 2; }
serial="$1"
out="$2"
published_dir="${3:-}"

[[ "$(id -u)" != 0 ]] || fail "Refused to run as root: this runs the core it builds."
[[ "${serial}" =~ ^[1-9][0-9]{0,17}$ ]] || fail "The serial '${serial}' is not a positive integer."
[[ ! -e "${out}" && ! -L "${out}" ]] || fail "${out} exists already: build.sh writes a folder that is not there yet."

# refs.env is read, never sourced: exactly the two lines, each a full commit
refs="$(cat "${ROOT}/refs.env")" || fail "refs.env cannot be read."
[[ "${refs}" =~ ^INSTALLER_COMMIT=([0-9a-f]{40})$'\n'CORE_COMMIT=([0-9a-f]{40})$ ]] ||
    fail "refs.env must be the two lines INSTALLER_COMMIT=<40 lower case hex> and CORE_COMMIT=<40 lower case hex>, and nothing else."
installer_commit="${BASH_REMATCH[1]}"
core_commit="${BASH_REMATCH[2]}"

# (an early, plain refusal; the installer's builder stays the reader of the file)
grep -Eq '^MODULE_[A-Z][A-Z0-9_]*_TAG=' "${ROOT}/modules.env" ||
    fail "modules.env lists no module: a catalogue with no module is not published."
[[ -z "${published_dir}" || -d "${published_dir}" ]] || fail "The published folder ${published_dir} is not a folder."
published2="" published3=""
[[ -z "${published_dir}" || ! -f "${published_dir}/catalogue-2.json" ]] || published2="${published_dir}/catalogue-2.json"
[[ -z "${published_dir}" || ! -f "${published_dir}/catalogue-3.json" ]] || published3="${published_dir}/catalogue-3.json"

installer_url="${GITHUB_BASE}/CasaOS-Install"
core_url="${GITHUB_BASE}/CasaOS"
max_file_kib=204800
max_file_text="200 MiB"
if [[ -n "${MODULES_TEST_INSTALLER_DIR:-}" ]]; then
    installer_url="file://${MODULES_TEST_INSTALLER_DIR}"
    echo "build.sh: test only: the installer is fetched from ${installer_url} (MODULES_TEST_INSTALLER_DIR), not from GitHub."
fi
if [[ -n "${MODULES_TEST_CORE_DIR:-}" ]]; then
    core_url="file://${MODULES_TEST_CORE_DIR}"
    echo "build.sh: test only: the core is fetched from ${core_url} (MODULES_TEST_CORE_DIR), not from GitHub."
fi
if [[ -n "${MODULES_TEST_MAX_FILE_KIB:-}" ]]; then
    [[ "${MODULES_TEST_MAX_FILE_KIB}" =~ ^[1-9][0-9]{0,8}$ ]] || fail "MODULES_TEST_MAX_FILE_KIB is not a positive number of KiB."
    max_file_kib="${MODULES_TEST_MAX_FILE_KIB}"
    max_file_text="${max_file_kib} KiB"
    echo "build.sh: test only: a downloaded file is bounded to ${max_file_text} (MODULES_TEST_MAX_FILE_KIB), not 200 MiB."
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# fetch DIR URL COMMIT WHAT PIN: a shallow fetch of exactly that commit, which must be in the history of
# the repository's main. GitHub also serves the head of every pull request (and objects of forks) from
# the same URL, so a commit that fetches is not yet a commit that the repository holds.
fetch() {
    local dir="$1" url="$2" commit="$3" what="$4" pin="$5" main=refs/remotes/pinned/main
    git init -q "${dir}" &&
        git -C "${dir}" fetch -q --depth 1 "${url}" "${commit}" &&
        git -C "${dir}" -c advice.detachedHead=false checkout -q FETCH_HEAD ||
        fail "The ${what} at ${commit} could not be fetched from ${url}."
    [[ "$(git -C "${dir}" rev-parse HEAD)" == "${commit}" ]] || fail "The ${what} fetched from ${url} is not at ${commit}."

    # first the recent history of main, then all of it before saying no: a shallow history can only miss
    # the commit, never find one that is not there
    git -C "${dir}" fetch -q --depth 50 "${url}" "+refs/heads/main:${main}" ||
        fail "The main branch of the ${what} could not be fetched from ${url} (there is none, or the fetch failed)."
    git -C "${dir}" merge-base --is-ancestor "${commit}" "${main}" && return 0
    git -C "${dir}" fetch -q --depth 2147483647 "${url}" "+refs/heads/main:${main}" ||
        fail "The main branch of the ${what} could not be fetched from ${url} (there is none, or the fetch failed)."
    git -C "${dir}" merge-base --is-ancestor "${commit}" "${main}" ||
        fail "${pin} ${commit} is not in the history of main of ${url}: pin a commit that is merged there."
}

fetch "${work}/installer" "${installer_url}" "${installer_commit}" installer INSTALLER_COMMIT
fetch "${work}/core" "${core_url}" "${core_commit}" core CORE_COMMIT
installer="${work}/installer/scripts"
result="${work}/result"
mkdir -p "${result}/mirror"

# the files of the module releases, under a bound on the size of any file written: an archive of an author
# is as large as the author makes it. A file cut at the bound is the sign of a larger one.
status=0
(
    # (the unit of the bound is the KiB of bash, not the 512 bytes of its POSIX mode; no core file of a process killed at the bound)
    unset POSIXLY_CORRECT
    set +o posix
    ulimit -c 0 2>/dev/null || true
    ulimit -f "${max_file_kib}" || exit 99
    exec env -u POSIXLY_CORRECT CHECKSUMS_BASE_URL="${GITHUB_BASE}" OWNERS_BASE_URL=https://github.com CARRY_CATALOGUE="${published3}" PYTHON="${PYTHON}" \
        bash "${installer}/stage-modules.sh" "${ROOT}/modules.env" "${work}/stage"
) || status=$?
if [[ "${status}" != 0 ]]; then
    [[ "${status}" != 99 ]] || fail "The bound on the size of a downloaded file could not be set."
    # (the stage folder may never have been made: a failure to find is no cut file)
    cut=""
    if [[ -d "${work}/stage" ]]; then
        cut="$(find "${work}/stage" -type f -size "$((max_file_kib * 1024))c" 2>/dev/null | head -n 1)" || cut=""
    fi
    if [[ -n "${cut}" ]]; then
        what="an archive"
        [[ "${cut##*/}" != checksums.txt ]] || what="a downloaded file"
        fail "The release files of the modules could not be fetched: ${what} is larger than ${max_file_text} (${cut#"${work}/stage/"})."
    fi
    fail "The release files of the modules could not be fetched, or one does not match its checksums.txt (see above)."
fi

generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
"${PYTHON}" "${installer}/build-modules-catalogue.py" build --git-base "${GITHUB_BASE}" --out "${result}/catalogue-2.json" \
    --schema 2 --serial "${serial}" --generated "${generated}" "${ROOT}/modules.env" "${work}/stage" ||
    fail "The catalogue was not built: a module does not hold (see above)."
carry=()
[[ -z "${published3}" ]] || carry=(--carry "${published3}")
"${PYTHON}" "${installer}/build-modules-catalogue.py" build --git-base "${GITHUB_BASE}" --out "${result}/catalogue-3.json" \
    --schema 3 --serial "${serial}" --generated "${generated}" --withdrawn "${ROOT}/withdrawn.txt" ${carry[@]+"${carry[@]}"} \
    "${ROOT}/modules.env" "${work}/stage" ||
    fail "The catalogue of schema 3 was not built: a module does not hold (see above)."

# the modules fetched now: the files to copy into this repository's releases, and for another owner the
# provenance and the licence of what an author published
fresh="$("${PYTHON}" "${installer}/build-modules-catalogue.py" list "${ROOT}/modules.env" ${carry[@]+"${carry[@]}"})" ||
    fail "The modules to fetch cannot be listed (see above)."
while read -r name component tag commit tier owner; do
    [[ -n "${name}" ]] || continue
    archives=("${work}/stage/${name}"/*.tar.gz)
    [[ ${#archives[@]} -eq 2 && -f "${archives[0]}" && -f "${work}/stage/${name}/checksums.txt" ]] ||
        fail "Module ${name}: the staged files are not checksums.txt and two archives."
    listed=0
    rc=0
    bash "${ROOT}/scripts/unattested.sh" has "${name}" "${tag}" || rc=$?
    case "${rc}" in 0) listed=1 ;; 1) ;; *) fail "unattested.txt cannot be read (see above)." ;; esac
    [[ "${listed}" == 0 || "${owner}" == ReCasaOS ]] ||
        fail "Module ${name}: unattested.txt lists ${tag}, but only a module of ReCasaOS can be exempt from provenance."
    # ours: provenance too, except the versions published before releases carried it (unattested.txt)
    if [[ "${listed}" == 0 ]]; then
        bash "${ROOT}/scripts/attest.sh" "${owner}/${component}" "${tag}" "${commit}" "${archives[@]}" ||
            fail "Module ${name}: the provenance of its archives is not established (see above)."
    fi
    if [[ "${owner}" != ReCasaOS ]]; then
        for archive in "${archives[@]}"; do
            "${PYTHON}" -I "${ROOT}/scripts/license.py" "${archive}" ||
                fail "Module ${name}: ${archive##*/} does not carry its licence (see above)."
        done
    fi
    mkdir "${result}/mirror/m-${name}-${tag}"
    cp "${work}/stage/${name}/checksums.txt" "${archives[@]}" "${result}/mirror/m-${name}-${tag}/"
done <<<"${fresh}"

if [[ -n "${published2}" ]]; then
    "${PYTHON}" -I "${ROOT}/scripts/compare.py" "${published2}" "${result}/catalogue-2.json" --schema 2 ||
        fail "The catalogue changes a module under a tag that is already published, or the published catalogue cannot be read (see above)."
fi
if [[ -n "${published3}" ]]; then
    "${PYTHON}" -I "${ROOT}/scripts/compare.py" "${published3}" "${result}/catalogue-3.json" --schema 3 ||
        fail "The catalogue of schema 3 changes a module under a tag that is already published, or the published one cannot be read (see above)."
fi
"${PYTHON}" -I "${ROOT}/scripts/names.py" "${result}/catalogue-3.json" "${ROOT}/retired.env" ${published3:+"${published3}"} ||
    fail "A name, a unit or a route of a retired module is taken, or a published module is gone without a line in retired.env (see above)."

# --- the proof: the core at CORE_COMMIT reads each file as its online catalogue
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

# probe N: the core lists its modules on catalogue-N.json as its online catalogue, and the result is judged
probe() {
    local n="$1" status=0
    cp "${result}/catalogue-${n}.json" "${proof}/catalogue-${n}.json"
    (
        ulimit -f 2048 2>/dev/null || true
        cd "${proof}"
        # CASAOS_MODULE_CATALOGUE names a file that does not exist: no shipped catalogue, only the online one
        exec timeout -k 5 "${PROBE_TIMEOUT}" env -i PATH="${PATH}" HOME="${proof}" CASAOS_MODULE_TEST=1 \
            CASAOS_MODULE_CATALOGUE="${proof}/no-shipped-catalogue.json" CASAOS_MODULE_ONLINE_CATALOGUE="${proof}/catalogue-${n}.json" \
            "${proof}/casaos" module list </dev/null >"${proof}/out-${n}" 2>"${proof}/err-${n}"
    ) || status=$?
    case "${status}" in
    0) ;;
    124 | 137) fail "The core at ${core_commit} did not answer 'casaos module list' within ${PROBE_TIMEOUT} seconds and was killed (catalogue-${n}.json)." ;;
    *) fail "The core at ${core_commit} failed 'casaos module list' with status ${status} (catalogue-${n}.json): $(head -c 300 "${proof}/err-${n}" | tr -c '[:print:]\n' '?')" ;;
    esac

    "${PYTHON}" "${installer}/build-modules-catalogue.py" proof "${ROOT}/modules.env" "${proof}/out-${n}" --schema "${n}" ||
        fail "The core at ${core_commit} does not take the catalogue catalogue-${n}.json, or does not list its modules (see above)."

    # proof does not tell the online file from a shipped one: the core must say it read this one, at this serial
    # (-I and no assert: no PYTHON* variable of the environment can turn this check off)
    "${PYTHON}" -I - "${proof}/out-${n}" "${serial}" <<'EOF' || fail "The core at ${core_commit} did not read the catalogue as its online catalogue at serial ${serial} (catalogue-${n}.json)."
import json, sys
out = json.load(open(sys.argv[1]))
online = out["catalogue"].get("online") or {}
if not (online.get("ok") is True and online.get("serial") == int(sys.argv[2])
        and all(m.get("source") == "online" for m in out["modules"])):
    sys.exit(1)
EOF
    echo "build.sh: the core at ${core_commit} reads catalogue-${n}.json as its online catalogue and lists its modules."
}
probe 2
probe 3

"${PYTHON}" -I - "${result}/catalogue-2.json" "${result}/catalogue-3.json" <<'EOF' || fail "The two catalogues do not have the same serial and the same time."
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:])
if (a["serial"], a["generated"]) != (b["serial"], b["generated"]):
    sys.exit(1)
EOF

mkdir -p "$(dirname "${out}")"
mv "${result}" "${out}" || { rm -rf "${out}"; fail "The catalogues could not be written to ${out}."; }
echo "build.sh: built ${out} (serial ${serial}): catalogue-2.json, catalogue-3.json and the archives to copy."
