#!/usr/bin/env bash
#
# Downloads the catalogues published now, the files every box reads, for
# scripts/build.sh (PUBLISHED) and scripts/summary.py:
#
#   scripts/published.sh OUTDIR
#
# The latest release (one `gh api repos/<repo>/releases/latest`, GH, default gh,
# on GITHUB_REPOSITORY, with a read token, GH_TOKEN) says which files it has:
#
# - catalogue-2.json is always there; catalogue-3.json only from the first
#   publication of schema 3, and its absence is read in that list, never in a 404;
# - each file listed is downloaded to OUTDIR (created if need be) from the
#   address the boxes read, https://github.com/ReCasaOS/modules/releases/latest/download/<file>
#   (CURL, default curl), HTTP 200 or a failure;
# - HTTP 404 on the latest release while the repository has no release at all:
#   nothing is published yet, exit 0 and OUTDIR is empty;
# - anything else (a 404 while a release exists, a latest release without
#   catalogue-2.json, another status, a failed download, releases that cannot be
#   listed): a non-zero exit, one sentence, and no file in OUTDIR.
#
# It judges nothing about the files' content: build.sh and compare.py do.
# A read token is shown published releases only, never drafts.

set -euo pipefail

readonly BASE=https://github.com/ReCasaOS/modules/releases/latest/download
GH="${GH:-gh}"
CURL="${CURL:-curl}"

[[ $# -eq 1 ]] || { echo "usage: scripts/published.sh OUTDIR" >&2; exit 2; }
outdir="$1"
repo="${GITHUB_REPOSITORY:-}"

clean() { rm -f "${outdir}/catalogue-2.json" "${outdir}/catalogue-3.json"; }
fail() {
    clean
    echo "published.sh: $*" >&2
    exit 1
}

mkdir -p "${outdir}" || fail "${outdir} cannot be made."
clean

err="$(mktemp)"
trap 'rm -f "${err}"' EXIT
if ! latest="$("${GH}" api "repos/${repo}/releases/latest" 2>"${err}")"; then
    # a 404 means "nothing published yet" only when there is no release at all
    grep -q 404 "${err}" || fail "The latest release of '${repo}' could not be read: $(head -c 200 "${err}" | tr -c '[:print:]' ' ')"
    releases="$("${GH}" api "repos/${repo}/releases?per_page=1")" ||
        fail "The releases of '${repo}' could not be listed, so the 404 on its latest release cannot be read as nothing published."
    count="$(python3 -I -c '
import json, sys
try:
    rel = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
if not isinstance(rel, list):
    sys.exit(1)
print(len(rel))
' "${releases}")" || fail "The releases of '${repo}' are not a list, so the 404 on its latest release cannot be read as nothing published."
    [[ "${count}" == 0 ]] ||
        fail "${repo} has a release, but its latest release cannot be read (HTTP 404); that is never read as nothing published."
    echo "published.sh: nothing is published yet (${repo} has no release)."
    exit 0
fi

files="$(python3 -I -c '
import json, sys
try:
    rel = json.loads(sys.argv[1])
    names = [a["name"] for a in rel["assets"]]
except (ValueError, KeyError, TypeError):
    sys.exit(1)
for n in ("catalogue-2.json", "catalogue-3.json"):
    if n in names:
        print(n)
' "${latest}")" || fail "The latest release of '${repo}' does not list its files."
grep -qx catalogue-2.json <<<"${files}" ||
    fail "The latest release of ${repo} has no catalogue-2.json; that is never read as nothing published."

for file in ${files}; do
    code="$("${CURL}" -sSL --retry 5 --retry-delay 10 -o "${outdir}/${file}" -w '%{http_code}' "${BASE}/${file}")" ||
        fail "The published ${file} could not be downloaded from ${BASE}/${file}."
    [[ "${code}" == 200 ]] || fail "The published ${file} answered HTTP ${code} at ${BASE}/${file}."
done
echo "published.sh: the published catalogue is in ${outdir}: $(echo ${files})."
