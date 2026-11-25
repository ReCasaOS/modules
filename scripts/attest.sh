#!/usr/bin/env bash
#
# Checks that archives of a module of another owner carry a provenance attestation,
# made by a workflow of that owner's repository at the pinned tag and commit:
#
#   scripts/attest.sh REPOSITORY TAG COMMIT ARCHIVE...
#
# REPOSITORY is <owner>/<repo>, TAG v<number>.<number>.<number>, COMMIT 40 lower case
# hexadecimal digits, each ARCHIVE an existing regular file; all are checked before
# the first call. Each archive is then verified by (GH, default gh)
#
#   gh attestation verify ARCHIVE --repo REPOSITORY --source-digest COMMIT \
#       --source-ref refs/tags/TAG --deny-self-hosted-runners
#
# The first failure stops there: one sentence that names the repository and the
# archive, says that the provenance is not established, and quotes the first 300
# printable characters of what gh said. Exit status: 0 every archive verified,
# 1 refused, 2 usage. It writes nothing.

set -euo pipefail

GH="${GH:-gh}"

usage() { echo "usage: scripts/attest.sh REPOSITORY TAG COMMIT ARCHIVE..." >&2; exit 2; }
# every printed value is cleaned: no newline, no control character, so none starts a line of a log
refuse() { printf 'attest.sh: %s\n' "$(printf '%s' "$*" | tr -c '[:print:]' ' ')" >&2; exit 1; }

[[ $# -ge 4 ]] || usage
repo="$1" tag="$2" commit="$3"
shift 3

# the owner and component patterns of the catalogue; ".." is refused although the component pattern allows dots
owner_re='[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?'
component_re='[A-Za-z][A-Za-z0-9._-]{0,63}'
[[ "${repo}" =~ ^${owner_re}/${component_re}$ && "${repo}" != *..* ]] || refuse "The repository '${repo}' is not <owner>/<repo>."
[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "The tag '${tag}' is not v<number>.<number>.<number>."
[[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || refuse "The commit '${commit}' is not 40 lower case hexadecimal digits."
for archive in "$@"; do
    [[ "${archive}" != -* && -f "${archive}" && ! -L "${archive}" ]] || refuse "The archive '${archive}' is not a regular file."
done

err="$(mktemp)"
trap 'rm -f "${err}"' EXIT
for archive in "$@"; do
    "${GH}" attestation verify "${archive}" --repo "${repo}" --source-digest "${commit}" --source-ref "refs/tags/${tag}" --deny-self-hosted-runners \
        >/dev/null 2>"${err}" ||
        refuse "The provenance of ${archive} is not established for ${repo} at ${tag}: $(tr -c '[:print:]' ' ' <"${err}" | head -c 300)"
done
