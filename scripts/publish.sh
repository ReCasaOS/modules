#!/usr/bin/env bash
#
# Publishes the catalogues built by scripts/build.sh as the assets catalogue-2.json and
# catalogue-3.json of the release c<SERIAL>, marked latest: the files every box reads at
# https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-2.json (and -3)
#
#   scripts/publish.sh SERIAL OUTDIR
#
# Run it after scripts/mirror.sh: the archives that catalogue-3.json names are by then in
# releases of this repository.
#
# 1. checks the two files of OUTDIR: a schema 2 and a schema 3 catalogue (the parser of
#    scripts/compare.py), each of the serial SERIAL, both with the same generated time;
# 2. reads the latest release (gh api repos/<repo>/releases/latest; none published at
#    all: serial 0) and the serial of its catalogue-2.json, and refuses SERIAL unless it is
#    higher, or when a release c<SERIAL> exists already, draft or not (looked up by its tag);
# 3. creates the release c<SERIAL> as a draft, on the commit GITHUB_SHA;
# 4. attaches both files, downloads each back from the draft and requires the same bytes;
# 5. only then publishes the draft as the latest release;
# 6. requires the latest release to be c<SERIAL>, downloads both files from it and requires
#    the same bytes again.
#
# Until step 5 the published catalogue does not change: a failure after step 3
# leaves the draft, unpublished, and says so. On any failure: a non-zero exit
# and one sentence saying what was left.
#
# Talks to GitHub only through gh (GH, default gh), on GITHUB_REPOSITORY, which
# must be ReCasaOS/modules. Needs GH_TOKEN with contents: write, GITHUB_SHA,
# python3.
#
# For the tests only (tests/test-publish.sh), said on the output when set:
#   MODULES_TEST_REPOSITORY  the repository accepted instead of ReCasaOS/modules

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ASSETS=(catalogue-2.json catalogue-3.json)
GH="${GH:-gh}"
draft="" # set once the draft release exists, and until it is published

fail() {
    local msg="$*"
    [[ -z "${draft}" ]] || msg="${msg%.}; the draft release ${draft} is left unpublished, and the published catalogue is unchanged."
    echo "publish.sh: ${msg}" >&2
    exit 1
}

[[ $# -eq 2 ]] || { echo "usage: scripts/publish.sh SERIAL OUTDIR" >&2; exit 2; }
serial="$1"
outdir="$2"

[[ "${serial}" =~ ^[1-9][0-9]{0,17}$ ]] || fail "The serial '${serial}' is not a positive integer."
expected=ReCasaOS/modules
if [[ -n "${MODULES_TEST_REPOSITORY:-}" ]]; then
    expected="${MODULES_TEST_REPOSITORY}"
    echo "publish.sh: test only: publishing to ${expected} (MODULES_TEST_REPOSITORY), not to ReCasaOS/modules."
fi
repo="${GITHUB_REPOSITORY:-}"
[[ "${repo}" == "${expected}" ]] || fail "This publishes to ${expected} only, not to '${repo}' (GITHUB_REPOSITORY)."
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail "GITHUB_SHA is not a full commit."

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
err="${work}/err"

# header_of FILE SCHEMA [SERIAL]: "<serial> <generated>" of a catalogue, checked by compare.py's strict parser. With
# SERIAL, the status is 3 (the line still printed) unless SERIAL is above it: compared in Python, as bash numbers wrap at 2^63.
header_of() {
    python3 -I - "${ROOT}/scripts" "$@" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import compare
try:
    serial, generated = compare.header(sys.argv[2], int(sys.argv[3]))
except compare.Refused as err:
    sys.exit(str(err))
print(serial, generated)
if len(sys.argv) > 4 and not int(sys.argv[4]) > serial:
    sys.exit(3)
EOF
}

# --- 1. the files: private copies under the assets' names, checked before anything is written
mkdir "${work}/new"
header=""
for i in 0 1; do
    cp "${outdir}/${ASSETS[i]}" "${work}/new/${ASSETS[i]}" || fail "${outdir}/${ASSETS[i]} cannot be read; nothing was written."
    h="$(header_of "${work}/new/${ASSETS[i]}" $((i + 2)) 2>"${err}")" ||
        fail "${outdir}/${ASSETS[i]} cannot be published ($(tr '\n' ' ' <"${err}")); nothing was written."
    [[ "${h%% *}" == "${serial}" ]] || fail "${outdir}/${ASSETS[i]} has the serial ${h%% *}, not ${serial}; nothing was written."
    [[ -z "${header}" || "${h}" == "${header}" ]] ||
        fail "The catalogue-2.json and the catalogue-3.json do not have the same generated time (${header#* }, ${h#* }); nothing was written."
    header="${h}"
done
sum2="$(sha256sum "${work}/new/catalogue-2.json" | cut -d' ' -f1)"
sum3="$(sha256sum "${work}/new/catalogue-3.json" | cut -d' ' -f1)"

# --- 2. what is published: read, never guessed (0 only when the repository has no release at all)
# latest_tag: the tag of the latest release, or "-" when there is none. Never found in a listing of releases: those pile up.
latest_tag() {
    local out
    if out="$("${GH}" api "repos/${repo}/releases/latest" 2>"${err}")"; then
        python3 -I -c '
import json, re, sys
try:
    tag = json.loads(sys.argv[1])["tag_name"]
except (ValueError, KeyError, TypeError):
    sys.exit(1)
if not isinstance(tag, str) or not re.fullmatch(r"c[1-9][0-9]*", tag):
    sys.exit(1)
print(tag)
' "${out}"
        return
    fi
    # a 404 means "nothing published yet" only when there is no release at all, drafts included
    grep -q 'HTTP 404' "${err}" || { echo "The latest release of ${repo} could not be read." >&2; return 1; }
    out="$("${GH}" api "repos/${repo}/releases?per_page=1" 2>"${err}")" || { echo "The releases of ${repo} could not be listed." >&2; return 1; }
    python3 -I -c '
import json, sys
try:
    rel = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
if not isinstance(rel, list) or rel:
    sys.exit(1)
print("-")
' "${out}"
}
latest="$(latest_tag 2>"${work}/why")" ||
    fail "The latest release of ${repo} is not read as a release c<serial>, nor as no release at all ($(tr '\n' ' ' <"${work}/why")); nothing was written."

# (nothing published: any serial passes, SERIAL is at least 1)
if [[ "${latest}" != - ]]; then
    mkdir "${work}/published"
    "${GH}" release download "${latest}" -R "${repo}" --pattern catalogue-2.json --dir "${work}/published" ||
        fail "The catalogue-2.json of the latest release ${latest} could not be downloaded; nothing was written."
    status=0
    published="$(header_of "${work}/published/catalogue-2.json" 2 "${serial}" 2>"${err}")" || status=$?
    [[ "${status}" == 0 || "${status}" == 3 ]] ||
        fail "The catalogue-2.json of the latest release ${latest} cannot be read ($(tr '\n' ' ' <"${err}")); nothing was written."
    [[ "${status}" == 0 ]] ||
        fail "The serial ${serial} is not above the published serial ${published%% *} (${latest}): the catalogue never goes back; nothing was written."
fi
# a re-run of a run keeps its serial, and a second draft under one tag would make every call below ambiguous
if "${GH}" release view "c${serial}" -R "${repo}" --json tagName,isDraft >/dev/null 2>"${err}"; then
    fail "A release c${serial} already exists (a draft left by an earlier attempt?): delete it, or run the workflow again for a new serial; nothing was written."
fi
[[ "$(<"${err}")" == "release not found" ]] ||
    fail "The release c${serial} could not be looked up ($(tr -c '[:print:]' ' ' <"${err}" | head -c 200)); nothing was written."

# --- 3. the draft
"${GH}" release create "c${serial}" -R "${repo}" --draft --target "${GITHUB_SHA}" --title "c${serial}" \
    --notes "Modules catalogue, serial ${serial}, built from ${GITHUB_SHA}. SHA-256 of catalogue-2.json: ${sum2}; of catalogue-3.json: ${sum3}" ||
    fail "The draft release c${serial} could not be created (delete it if it appears as a draft); nothing was published."
draft="c${serial}"

# --- 4. the files, and the same bytes back from GitHub
"${GH}" release upload "c${serial}" "${work}/new/catalogue-2.json" "${work}/new/catalogue-3.json" -R "${repo}" ||
    fail "The catalogues could not be attached to c${serial}."
mkdir "${work}/back"
for f in "${ASSETS[@]}"; do
    "${GH}" release download "c${serial}" -R "${repo}" --pattern "${f}" --dir "${work}/back" ||
        fail "The ${f} attached to c${serial} could not be downloaded back."
    cmp -s "${work}/back/${f}" "${work}/new/${f}" ||
        fail "The ${f} attached to c${serial} is not the file built (SHA-256 $(sha256sum "${work}/back/${f}" | cut -d' ' -f1), built $(sha256sum "${work}/new/${f}" | cut -d' ' -f1))."
done

# --- 5. publish
draft=""
"${GH}" release edit "c${serial}" -R "${repo}" --draft=false --latest ||
    fail "The draft release c${serial} could not be published: check on the releases page whether it is published or still a draft."

# --- 6. what the latest release serves now
now="$(latest_tag 2>"${work}/why")" || fail "c${serial} is published, but the latest release could not be read ($(tr '\n' ' ' <"${work}/why")): check it now."
[[ "${now}" == "c${serial}" ]] || fail "c${serial} is published, but the latest release is ${now}: check it now."
mkdir "${work}/latest"
for f in "${ASSETS[@]}"; do
    "${GH}" release download -R "${repo}" --pattern "${f}" --dir "${work}/latest" ||
        fail "c${serial} is published, but the ${f} of the latest release could not be read back: check it now."
    cmp -s "${work}/latest/${f}" "${work}/new/${f}" ||
        fail "c${serial} is published, but the latest release serves another ${f} (SHA-256 $(sha256sum "${work}/latest/${f}" | cut -d' ' -f1), published $(sha256sum "${work}/new/${f}" | cut -d' ' -f1)): check it now."
done

echo "publish.sh: published c${serial} as the latest release of ${repo}; SHA-256 of its catalogue-2.json: ${sum2}; of its catalogue-3.json: ${sum3}."
