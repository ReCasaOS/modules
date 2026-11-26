#!/usr/bin/env bash
#
# The list of the module versions of ReCasaOS that were published before releases carried
# provenance (unattested.txt, one "<name> <tag>" per line, # comments allowed):
#
#   scripts/unattested.sh has NAME TAG      exit 0 if the version is listed, 1 if not
#   scripts/unattested.sh check BASE_REF    exit 0 if every line of the file is already in
#                                           unattested.txt at BASE_REF: the list only shrinks
#
# A BASE_REF without the file counts as an empty list, except for the versions the list was
# created with (FIRST below): the change that creates the file may list those and nothing else.
#
# Exit status 2: usage, or a line of the file that is not "<name> <tag>". UNATTESTED_FILE
# names another file (tests only).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="${UNATTESTED_FILE:-${ROOT}/unattested.txt}"

# the versions published before releases carried provenance, when the list was created
FIRST="virt v0.2.7
vuln-scan v0.2.1
mcp v0.2.2"

die() { echo "unattested.sh: $*" >&2; exit 2; }

# lines FILE: the "<name> <tag>" lines, comments and blanks dropped, each checked
lines() {
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
        [[ "${line}" =~ ^[a-z][a-z0-9-]*\ v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'${line}' is not '<name> <tag>'."
        printf '%s\n' "${line}"
    done
}

case "${1:-}" in
has)
    [[ $# -eq 3 ]] || die "usage: scripts/unattested.sh has NAME TAG"
    [[ -f "${file}" ]] || exit 1
    lines <"${file}" | grep -Fxq -- "$2 $3"
    ;;
check)
    [[ $# -eq 2 ]] || die "usage: scripts/unattested.sh check BASE_REF"
    [[ -f "${file}" ]] || exit 0
    git -C "${ROOT}" rev-parse -q --verify "$2^{commit}" >/dev/null || die "$2 is not a commit: nothing to compare with."
    if base="$(git -C "${ROOT}" show "$2:unattested.txt" 2>/dev/null)"; then
        base="$(lines <<<"${base}")" || exit 2
    else
        echo "unattested.sh: no unattested.txt at $2: only the versions it was created with may be listed." >&2
        base="${FIRST}"
    fi
    current="$(lines <"${file}")" || exit 2
    status=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] || grep -Fxq -- "${line}" <<<"${base}" || { echo "unattested.sh: '${line}' is not in unattested.txt at $2: the list only shrinks, a new version carries provenance." >&2; status=1; }
    done <<<"${current}"
    exit "${status}"
    ;;
*) die "usage: scripts/unattested.sh has NAME TAG | check BASE_REF" ;;
esac
