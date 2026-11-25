#!/usr/bin/env bash
#
# Downloads the catalogue published now, the file every box reads, for
# scripts/build.sh (PUBLISHED) and scripts/summary.py:
#
#   scripts/published.sh OUT
#
# - HTTP 200: the file is written to OUT, exit 0;
# - HTTP 404 while the repository has no published release at all: nothing is
#   published yet, exit 0 and no file at OUT;
# - anything else (a 404 while a release exists, another status, a failed
#   download, releases that cannot be listed): a non-zero exit, one sentence,
#   and no file at OUT.
#
# It judges nothing about the file's content: build.sh and compare.py do.
#
# Whether a release exists is asked through `gh api` (GH, default gh) on
# GITHUB_REPOSITORY, with a read token (GH_TOKEN): such a token is shown
# published releases only, never drafts. Downloads with curl (CURL, default curl).

set -euo pipefail

readonly URL=https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-2.json
GH="${GH:-gh}"
CURL="${CURL:-curl}"

[[ $# -eq 1 ]] || { echo "usage: scripts/published.sh OUT" >&2; exit 2; }
out="$1"

fail() {
    rm -f "${out}"
    echo "published.sh: $*" >&2
    exit 1
}

rm -f "${out}"
code="$("${CURL}" -sSL --retry 5 --retry-delay 10 -o "${out}" -w '%{http_code}' "${URL}")" ||
    fail "The published catalogue could not be downloaded from ${URL}."
case "${code}" in
200)
    echo "published.sh: the published catalogue is in ${out}."
    exit 0
    ;;
404) rm -f "${out}" ;;
*) fail "The published catalogue answered HTTP ${code} at ${URL}." ;;
esac

# a 404 means "nothing published yet" only when there is no release at all
repo="${GITHUB_REPOSITORY:-}"
releases="$("${GH}" api "repos/${repo}/releases?per_page=1")" ||
    fail "The releases of '${repo}' could not be listed, so the 404 at ${URL} cannot be read as nothing published."
count="$(python3 -I -c '
import json, sys
try:
    rel = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
if not isinstance(rel, list):
    sys.exit(1)
print(len(rel))
' "${releases}")" || fail "The releases of '${repo}' are not a list, so the 404 at ${URL} cannot be read as nothing published."
[[ "${count}" == 0 ]] ||
    fail "${repo} has a release, but the latest release serves no catalogue-2.json (HTTP 404); that is never read as nothing published."
echo "published.sh: nothing is published yet (HTTP 404, and ${repo} has no release)."
