#!/usr/bin/env bash
#
# Publishes a catalogue built by scripts/build.sh as the asset catalogue-2.json
# of the release c<SERIAL>, marked latest: the file every box reads at
# https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-2.json
#
#   scripts/publish.sh SERIAL FILE
#
# 1. checks FILE: a schema 2 catalogue (the parser of scripts/compare.py) whose
#    serial is SERIAL;
# 2. reads the serial of the catalogue-2.json of the latest release (none
#    published yet: 0) and refuses SERIAL unless it is higher, or when a release
#    c<SERIAL> exists already, draft or not;
# 3. creates the release c<SERIAL> as a draft, on the commit GITHUB_SHA;
# 4. attaches FILE as catalogue-2.json, downloads it back from the draft and
#    requires the same bytes;
# 5. only then publishes the draft as the latest release;
# 6. downloads the catalogue-2.json of the latest release and requires the
#    same bytes again.
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
readonly ASSET=catalogue-2.json
GH="${GH:-gh}"
draft="" # set once the draft release exists, and until it is published

fail() {
    local msg="$*"
    [[ -z "${draft}" ]] || msg="${msg%.}; the draft release ${draft} is left unpublished, and the published catalogue is unchanged."
    echo "publish.sh: ${msg}" >&2
    exit 1
}

[[ $# -eq 2 ]] || { echo "usage: scripts/publish.sh SERIAL FILE" >&2; exit 2; }
serial="$1"
file="$2"

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

# serial_of FILE [SERIAL]: the serial of a schema 2 catalogue, checked by compare.py's strict parser. With SERIAL, the
# status is 3 (the serial still printed) unless SERIAL is above it: compared in Python, as bash numbers wrap at 2^63.
serial_of() {
    python3 -I - "${ROOT}/scripts" "$@" <<'EOF'
import json, sys
sys.path.insert(0, sys.argv[1])
import compare
try:
    compare.load(sys.argv[2])
except compare.Refused as err:
    sys.exit(str(err))
serial = json.load(open(sys.argv[2], encoding="utf-8"))["serial"]
print(serial)
if len(sys.argv) > 3 and not int(sys.argv[3]) > serial:
    sys.exit(3)
EOF
}

# --- 1. the file: a private copy under the asset's name, checked before anything is written
mkdir "${work}/new"
cp "${file}" "${work}/new/${ASSET}" || fail "${file} cannot be read; nothing was written."
new="${work}/new/${ASSET}"
file_serial="$(serial_of "${new}")" || fail "${file} cannot be published (see above); nothing was written."
[[ "${file_serial}" == "${serial}" ]] || fail "${file} has the serial ${file_serial}, not ${serial}; nothing was written."
sum="$(sha256sum "${new}" | cut -d' ' -f1)"

# --- 2. what is published: read, never guessed (0 only when no release is published at all)
releases="$("${GH}" release list -R "${repo}" --limit 100 --json tagName,isDraft,isLatest)" ||
    fail "The releases of ${repo} could not be listed; nothing was written."
state="$(python3 -I - "c${serial}" "${releases}" <<'EOF'
import json, sys
sys.tracebacklimit = 0
rel = json.loads(sys.argv[2])
assert isinstance(rel, list) and all(isinstance(r, dict) and isinstance(r.get("tagName"), str) for r in rel)
latest = [r["tagName"] for r in rel if r.get("isLatest") is True]
assert len(latest) <= 1 and (latest or all(r.get("isDraft") is True for r in rel))
print(latest[0] if latest else "-", "taken" if any(r["tagName"] == sys.argv[1] for r in rel) else "free")
EOF
)" || fail "The releases of ${repo} do not say which one is latest; nothing was written."
read -r latest taken <<<"${state}"

# (nothing published: any serial passes, SERIAL is at least 1)
if [[ "${latest}" != - ]]; then
    mkdir "${work}/published"
    "${GH}" release download "${latest}" -R "${repo}" --pattern "${ASSET}" --dir "${work}/published" ||
        fail "The ${ASSET} of the latest release ${latest} could not be downloaded; nothing was written."
    status=0
    published="$(serial_of "${work}/published/${ASSET}" "${serial}")" || status=$?
    [[ "${status}" == 0 || "${status}" == 3 ]] ||
        fail "The ${ASSET} of the latest release ${latest} cannot be read (see above); nothing was written."
    [[ "${status}" == 0 ]] ||
        fail "The serial ${serial} is not above the published serial ${published} (${latest}): the catalogue never goes back; nothing was written."
fi
# a re-run of a run keeps its serial, and a second draft under one tag would make every call below ambiguous
[[ "${taken}" == free ]] ||
    fail "A release c${serial} already exists (a draft left by an earlier attempt?): delete it, or run the workflow again for a new serial; nothing was written."

# --- 3. the draft
"${GH}" release create "c${serial}" -R "${repo}" --draft --target "${GITHUB_SHA}" --title "c${serial}" \
    --notes "Modules catalogue, serial ${serial}, built from ${GITHUB_SHA}. SHA-256 of ${ASSET}: ${sum}" ||
    fail "The draft release c${serial} could not be created (delete it if it appears as a draft); nothing was published."
draft="c${serial}"

# --- 4. the file, and the same bytes back from GitHub
"${GH}" release upload "c${serial}" "${new}" -R "${repo}" || fail "${ASSET} could not be attached to c${serial}."
mkdir "${work}/back"
"${GH}" release download "c${serial}" -R "${repo}" --pattern "${ASSET}" --dir "${work}/back" ||
    fail "The ${ASSET} attached to c${serial} could not be downloaded back."
cmp -s "${work}/back/${ASSET}" "${new}" ||
    fail "The ${ASSET} attached to c${serial} is not the file built (SHA-256 $(sha256sum "${work}/back/${ASSET}" | cut -d' ' -f1), built ${sum})."

# --- 5. publish
draft=""
"${GH}" release edit "c${serial}" -R "${repo}" --draft=false --latest ||
    fail "The draft release c${serial} could not be published: check on the releases page whether it is published or still a draft."

# --- 6. what the latest release serves now
mkdir "${work}/latest"
"${GH}" release download -R "${repo}" --pattern "${ASSET}" --dir "${work}/latest" ||
    fail "c${serial} is published, but the ${ASSET} of the latest release could not be read back: check it now."
cmp -s "${work}/latest/${ASSET}" "${new}" ||
    fail "c${serial} is published, but the latest release serves another ${ASSET} (SHA-256 $(sha256sum "${work}/latest/${ASSET}" | cut -d' ' -f1), published ${sum}): check it now."

echo "publish.sh: published c${serial} as the latest release of ${repo}; SHA-256 of its ${ASSET}: ${sum}."
