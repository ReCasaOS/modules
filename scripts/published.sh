#!/usr/bin/env bash
#
# Downloads the catalogues published now, the files every box reads, for
# scripts/build.sh (PUBLISHED) and scripts/summary.py:
#
#   scripts/published.sh OUTDIR
#
# The latest release (one `gh api repos/<repo>/releases/latest`, GH, default gh,
# on GITHUB_REPOSITORY, with a read token, GH_TOKEN) says its tag (c<serial>) and which
# files it has; both are taken from that one answer, so that the files are those of one release:
#
# - catalogue-2.json is always there; catalogue-3.json only from the first
#   publication of schema 3, and its absence is read in that list, never in a 404;
# - each file listed is downloaded to OUTDIR (created if need be) from
#   https://github.com/<repo>/releases/download/<tag>/<file> (CURL, default curl; 1 MiB
#   at most), HTTP 200 or a failure; when both files are there they must have the same
#   serial and the same generated time;
# - HTTP 404 on the latest release (gh says "HTTP 404") while the repository has no release at all:
#   nothing is published yet, exit 0 and OUTDIR is empty;
# - anything else (a 404 while a release exists, a latest release without
#   catalogue-2.json, another status, a failed download, releases that cannot be
#   listed): a non-zero exit, one sentence, and no file in OUTDIR.
#
# It judges nothing about the files' content: build.sh and compare.py do.
# A read token is shown published releases only, never drafts.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

name="${repo#*/}"
[[ "${repo}" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ && "${name}" != . && "${name}" != .. ]] || { clean; fail "GITHUB_REPOSITORY '${repo}' is not <owner>/<repository>."; }
mkdir -p "${outdir}" || fail "${outdir} cannot be made."
clean

err="$(mktemp)"
trap 'rm -f "${err}"' EXIT
if ! latest="$("${GH}" api "repos/${repo}/releases/latest" 2>"${err}")"; then
    # a 404 means "nothing published yet" only when there is no release at all
    grep -q 'HTTP 404' "${err}" || fail "The latest release of '${repo}' could not be read: $(head -c 200 "${err}" | tr -c '[:print:]' ' ')"
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
import json, re, sys
try:
    rel = json.loads(sys.argv[1])
    names = [a["name"] for a in rel["assets"]]
    tag = rel["tag_name"]
except (ValueError, KeyError, TypeError):
    sys.exit(1)
if not isinstance(tag, str) or not re.fullmatch(r"c[1-9][0-9]*", tag):
    sys.exit(1)
print(tag)
for n in ("catalogue-2.json", "catalogue-3.json"):
    if n in names:
        print(n)
' "${latest}")" || fail "The latest release of '${repo}' does not name its tag as c<serial>, or does not list its files."
tag="${files%%$'
'*}"
files="${files#"${tag}"}"
grep -qx catalogue-2.json <<<"${files}" ||
    fail "The latest release ${tag} of ${repo} has no catalogue-2.json; that is never read as nothing published."

for file in ${files}; do
    url="https://github.com/${repo}/releases/download/${tag}/${file}"
    code="$("${CURL}" -sSL --retry 5 --retry-delay 10 --max-filesize 1048576 -o "${outdir}/${file}" -w '%{http_code}' "${url}")" ||
        fail "The published ${file} could not be downloaded from ${url} (or is larger than 1 MiB)."
    [[ "${code}" == 200 ]] || fail "The published ${file} answered HTTP ${code} at ${url}."
done

# one release, one serial and one time: the two files are not of two publications
if [[ -f "${outdir}/catalogue-3.json" ]]; then
    python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
import compare
try:
    same = compare.header(sys.argv[2], 2) == compare.header(sys.argv[3], 3)
except compare.Refused as err:
    sys.exit(str(err))
if not same:
    sys.exit("the catalogue-2.json and the catalogue-3.json of the latest release " + sys.argv[4] + " do not have the same serial and generated time.")
' "${ROOT}/scripts" "${outdir}/catalogue-2.json" "${outdir}/catalogue-3.json" "${tag}" 2>"${err}" || fail "$(tr '
' ' ' <"${err}")"
fi
echo "published.sh: the published catalogue (${tag}) is in ${outdir}: $(echo ${files})."
