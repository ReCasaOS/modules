#!/usr/bin/env bash
#
# Copies the archives of the catalogue into releases of this repository, the addresses
# that catalogue-3.json gives, before that catalogue is published:
#
#   scripts/mirror.sh OUTDIR
#
# OUTDIR is what scripts/build.sh wrote (and what the build job handed on): this script
# trusts nothing in it. It reads OUTDIR/catalogue-3.json with the strict parser of
# scripts/compare.py and, for each entry, takes the release m-<name>-<tag> and the two file
# names from the entry's archive addresses (the exact form is required). Each release is
# looked up by its tag (gh release view), and:
#
# - published: it must hold exactly checksums.txt and the two archives, and each archive
#   the SHA-256 of the catalogue (the digest that the API gives, else the archive is
#   downloaded and hashed). Another file or another sum stops the run: a published release
#   is never changed;
# - a draft: the run stops and says to delete it (a draft is what an earlier try left);
# - absent: OUTDIR/mirror/m-<name>-<tag>/ must hold exactly checksums.txt and the two
#   archives; each archive is hashed again and must have the SHA-256 of the catalogue and,
#   for a module of another owner than ReCasaOS, the one that modules.env pins
#   (MODULE_<NAME>_SHA256_AMD64 and _ARM64, one line each, read here and nowhere else);
#   checksums.txt must carry both archives' lines.
#
# A folder of OUTDIR/mirror that no entry names stops the run. All of that is checked, for
# every entry, before the first release is created: a bad artifact creates nothing.
#
# Then each missing release is made, one after the other, on the commit GITHUB_SHA:
# a draft, the three files attached, each downloaded back and compared byte for byte, then
# published with --draft=false --latest=false, read back (published, the three files, the
# sums, and not the latest release). A failure after a draft exists names that draft and
# leaves it unpublished. Nothing is ever replaced or deleted.
#
# Talks to GitHub only through gh (GH, default gh), on GITHUB_REPOSITORY, which must be
# ReCasaOS/modules. Needs GH_TOKEN with contents: write, GITHUB_SHA, python3.
#
# For the tests only (tests/test-mirror.sh), each said on the output when set:
#   MODULES_TEST_REPOSITORY  the repository accepted instead of ReCasaOS/modules
#   MODULES_TEST_ENV_FILE    the modules.env read instead of this repository's

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH="${GH:-gh}"
draft="" # set once a draft release exists, and until it is published

fail() {
    local msg="$*"
    [[ -z "${draft}" ]] || msg="${msg%.}; the draft release ${draft} is left unpublished: delete it, then run again."
    echo "mirror.sh: ${msg}" >&2
    exit 1
}

[[ $# -eq 1 ]] || { echo "usage: scripts/mirror.sh OUTDIR" >&2; exit 2; }
outdir="$1"

expected=ReCasaOS/modules
if [[ -n "${MODULES_TEST_REPOSITORY:-}" ]]; then
    expected="${MODULES_TEST_REPOSITORY}"
    echo "mirror.sh: test only: copying to ${expected} (MODULES_TEST_REPOSITORY), not to ReCasaOS/modules."
fi
repo="${GITHUB_REPOSITORY:-}"
[[ "${repo}" == "${expected}" ]] || fail "This copies into ${expected} only, not into '${repo}' (GITHUB_REPOSITORY)."
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail "GITHUB_SHA is not a full commit."
envfile="${ROOT}/modules.env"
if [[ -n "${MODULES_TEST_ENV_FILE:-}" ]]; then
    envfile="${MODULES_TEST_ENV_FILE}"
    echo "mirror.sh: test only: pinned sums read from ${envfile} (MODULES_TEST_ENV_FILE)."
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
err="${work}/err"
n=0

# modules.env, read to the letter: the builder strips each line, this job matches whole lines, so a line that is neither
# empty, a comment at column 0 nor KEY=value without a blank is refused (and with it any tab or carriage return)
lineno=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    [[ -z "${line}" || "${line}" == "#"* || "${line}" =~ ^[A-Z][A-Z0-9_]*=[^[:space:]]*$ ]] ||
        fail "modules.env line ${lineno} is none of: empty, a comment starting at column 0, NAME=value with no blank; nothing was written."
done <"${envfile}"
! grep -q $'[\t\r]' "${envfile}" || fail "modules.env holds a tab or a carriage return; nothing was written."

# --- the entries of the catalogue: one line each, tab separated: tag repository name file-amd64 sum-amd64 file-arm64 sum-arm64 version component
plan="$(python3 -I - "${ROOT}/scripts" "${outdir}" 2>"${err}" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[1])
import compare
out = sys.argv[2]
try:
    entries = compare.load(os.path.join(out, "catalogue-3.json"), 3)
except compare.Refused as exc:
    sys.exit(str(exc))
tags = set()
for name, e in entries.items():
    tag = "m-%s-%s" % (name, e["tag"])
    prefix = "%s%s/" % (compare.MIRROR_URL, tag)
    row = [tag, e["repository"], name]
    for arch in ("amd64", "arm64"):
        url = e["assets"][arch]["url"]
        file = url[len(prefix):]
        m = compare.ARCHIVE_RE.fullmatch(file)
        if not url.startswith(prefix) or not m or m.group(1) != arch or m.group(2) != e["tag"]:
            sys.exit("Module %s, %s: the archive is not at %s." % (name, arch, prefix))
        row += [file, e["assets"][arch]["sha256"]]
    tags.add(tag)
    print("\t".join(row + [e["tag"], e["component"]]))
mirror = os.path.join(out, "mirror")
if os.path.lexists(mirror):
    if os.path.islink(mirror) or not os.path.isdir(mirror):
        sys.exit("The artifact's mirror is not a folder.")
    for d in sorted(os.listdir(mirror)):
        if d not in tags:
            sys.exit("The artifact has mirror/%s, which no entry of catalogue-3.json names." % d)
EOF
)" || fail "$(tr '\n' ' ' <"${err}")"
[[ -n "${plan}" ]] || fail "catalogue-3.json has no module."

# --- GitHub's answers
declare -A dig
state=""

# view_release TAG: state = absent | draft | published; for the others dig = {file: digest or -}.
# A tag that is not found is told by gh's own sentence, "release not found", and by nothing else.
view_release() {
    local out lines
    if ! out="$("${GH}" release view "$1" -R "${repo}" --json tagName,isDraft,assets 2>"${err}")"; then
        [[ "$(<"${err}")" == "release not found" ]] ||
            fail "The release $1 could not be read: $(tr -c '[:print:]' ' ' <"${err}" | head -c 200)"
        state=absent
        return 0
    fi
    out="$(python3 -I -c '
import json, re, sys
try:
    r = json.loads(sys.argv[1])
    assert r["tagName"] == sys.argv[2] and isinstance(r["isDraft"], bool)
    print("draft" if r["isDraft"] else "published")
    for a in r["assets"]:
        d = a.get("digest")
        assert re.fullmatch(r"[A-Za-z0-9._-]+", a["name"])
        print(a["name"], d if isinstance(d, str) and d and " " not in d else "-")
except (ValueError, KeyError, TypeError, AssertionError, AttributeError):
    sys.exit(1)
' "${out}" "$1")" || fail "The answer of GitHub about the release $1 cannot be read."
    mapfile -t lines <<<"${out}"
    state="${lines[0]}"
    dig=()
    local l
    for l in "${lines[@]:1}"; do dig["${l%% *}"]="${l#* }"; done
}

sum_of() { sha256sum "$1" | cut -d' ' -f1; }

# download_of TAG FILE: path of that file of the release, downloaded to a folder of its own
download_of() {
    n=$((n + 1))
    mkdir "${work}/dl${n}"
    "${GH}" release download "$1" -R "${repo}" --pattern "$2" --dir "${work}/dl${n}" >/dev/null 2>"${err}" ||
        fail "The file $2 of the release $1 could not be downloaded: $(tr -c '[:print:]' ' ' <"${err}" | head -c 200)"
    got_path="${work}/dl${n}/$2"
}

# check_published TAG FILE SUM FILE SUM: what view_release read holds exactly the three files, and the two sums
check_published() {
    local tag="$1" f s got
    [[ ${#dig[@]} -eq 3 && -n "${dig[checksums.txt]+x}" && -n "${dig[$2]+x}" && -n "${dig[$4]+x}" ]] ||
        fail "The release ${tag} holds '${!dig[*]}', not exactly checksums.txt, $2 and $4; a published release is never changed, so nothing was written."
    shift
    while [[ $# -gt 0 ]]; do
        f="$1" s="$2"
        shift 2
        if [[ "${dig[$f]}" =~ ^sha256:([0-9a-f]{64})$ ]]; then
            got="${BASH_REMATCH[1]}"
        else
            download_of "${tag}" "${f}"
            got="$(sum_of "${got_path}")"
        fi
        [[ "${got}" == "${s}" ]] ||
            fail "The release ${tag} holds ${f} with the SHA-256 ${got}, and the catalogue says ${s}; a published release is never changed, so nothing was written."
    done
}

# env_value KEY REGEX [OPTIONAL]: val = the value of the one line KEY=<value> of modules.env, which must match REGEX in full.
# With OPTIONAL, no line at all is val="" ; two lines, or one that does not match, never pass.
env_value() {
    local lines
    mapfile -t lines < <(grep "^$1=" "${envfile}" || true)
    val=""
    [[ ${#lines[@]} -eq 0 && -n "${3:-}" ]] && return 0
    [[ ${#lines[@]} -eq 1 && "${lines[0]#"$1="}" =~ ^($2)$ ]] ||
        fail "modules.env has not exactly one line $1=<value>; nothing was written."
    val="${lines[0]#"$1="}"
}

# bind NAME VERSION REPOSITORY COMPONENT SUM SUM: the entry is the module modules.env lists, in the owner's repository,
# and (for an owner other than ReCasaOS) with the two sums that modules.env pins. owner = that owner.
bind() {
    local up arch sum
    up="$(tr 'a-z-' 'A-Z_' <<<"$1")"
    env_value "MODULE_${up}_TAG" 'v[0-9]+\.[0-9]+\.[0-9]+' optional
    [[ -n "${val}" ]] || fail "The catalogue holds the module $1, which modules.env does not list; nothing was written."
    [[ "${val}" == "$2" ]] || fail "The catalogue has $1 at ${2}, and modules.env lists it at ${val}; nothing was written."
    env_value "MODULE_${up}_COMPONENT" '[A-Za-z][A-Za-z0-9._-]*'
    [[ "${val}" == "$4" ]] || fail "The catalogue has the component $4 for $1, and modules.env lists ${val}; nothing was written."
    env_value "MODULE_${up}_OWNER" '[A-Za-z0-9-]+' optional
    owner="${val:-ReCasaOS}"
    [[ "$3" == "${owner}/$4" ]] || fail "The catalogue has the repository $3 for $1, and modules.env lists ${owner}/$4; nothing was written."
    [[ "${owner}" == ReCasaOS ]] && return 0
    for arch in amd64 arm64; do
        env_value "MODULE_${up}_SHA256_$(tr 'a-z' 'A-Z' <<<"${arch}")" '[0-9a-f]{64}'
        [[ "${arch}" == amd64 ]] && sum="$5" || sum="$6"
        [[ "${val}" == "${sum}" ]] || fail "modules.env pins ${val} for $1 (${arch}), and the catalogue says ${sum}; nothing was written."
    done
}

# verify_local TAG FILE SUM FILE SUM: the folder of the artifact for a release that is not there yet
verify_local() {
    local tag="$1" dir="${outdir}/mirror/$1" listing want f s got
    [[ -d "${dir}" && ! -L "${dir}" ]] ||
        fail "The release ${tag} does not exist, and the artifact has no mirror/${tag} to make it from; nothing was written."
    listing="$(find "${dir}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -)"
    want="$(printf '%s\n' checksums.txt "$2" "$4" | LC_ALL=C sort | paste -sd' ' -)"
    [[ "${listing}" == "${want}" ]] || fail "mirror/${tag} holds '${listing}', not '${want}'; nothing was written."
    for f in checksums.txt "$2" "$4"; do
        [[ -f "${dir}/${f}" && ! -L "${dir}/${f}" ]] || fail "mirror/${tag}/${f} is not a regular file; nothing was written."
    done
    for a in "$2:$3" "$4:$5"; do
        IFS=: read -r f s <<<"${a}"
        got="$(sum_of "${dir}/${f}")"
        [[ "${got}" == "${s}" ]] ||
            fail "The archive ${f} of the artifact has the SHA-256 ${got}, and the catalogue says ${s}; nothing was written."
    done
    # exactly the two lines "<sum>  <file>", in either order: the builder reads this file more loosely than that
    printf '%s  %s\n%s  %s\n' "$3" "$2" "$5" "$4" >"${work}/sums1"
    printf '%s  %s\n%s  %s\n' "$5" "$4" "$3" "$2" >"${work}/sums2"
    cmp -s "${dir}/checksums.txt" "${work}/sums1" || cmp -s "${dir}/checksums.txt" "${work}/sums2" ||
        fail "mirror/${tag}/checksums.txt is not exactly the two lines '<SHA-256>  <file>' of $2 and $4; nothing was written."
}

# --- 1. every release is looked up and every archive to copy is checked, before anything is created
todo=()
names=()
there=0
while IFS=$'\t' read -r tag repository name fa sa fb sb version component; do
    bind "${name}" "${version}" "${repository}" "${component}" "${sa}" "${sb}"
    names+=("${name}")
    view_release "${tag}"
    case "${state}" in
    draft) fail "The release ${tag} exists as a draft, left by an earlier try: delete the draft ${tag} and run again; nothing was written." ;;
    published)
        check_published "${tag}" "${fa}" "${sa}" "${fb}" "${sb}"
        there=$((there + 1))
        ;;
    absent)
        verify_local "${tag}" "${fa}" "${sa}" "${fb}" "${sb}"
        todo+=("${tag}"$'\t'"${owner}"$'\t'"${name}"$'\t'"${fa}"$'\t'"${sa}"$'\t'"${fb}"$'\t'"${sb}")
        ;;
    esac
done <<<"${plan}"

# every module that modules.env lists has its entry
while read -r key; do
    name="$(tr 'A-Z_' 'a-z-' <<<"${key}")"
    [[ " ${names[*]} " == *" ${name} "* ]] || fail "modules.env lists the module ${name}, and the catalogue has no entry for it; nothing was written."
done < <(sed -n 's/^MODULE_\([A-Z][A-Z0-9_]*\)_TAG=.*/\1/p' "${envfile}")

# --- 2. each missing release, one after the other
for row in "${todo[@]}"; do
    IFS=$'\t' read -r tag owner name fa sa fb sb <<<"${row}"
    dir="${outdir}/mirror/${tag}"
    "${GH}" release create "${tag}" -R "${repo}" --draft --target "${GITHUB_SHA}" --title "${tag}" \
        --notes "Archives of the module ${name} ${tag#m-"${name}"-}, copied here from the repository that published them. SHA-256: amd64 ${sa}, arm64 ${sb}." ||
        fail "The draft release ${tag} could not be created (delete it if it appears as a draft); nothing was published."
    draft="${tag}"
    "${GH}" release upload "${tag}" "${dir}/checksums.txt" "${dir}/${fa}" "${dir}/${fb}" -R "${repo}" ||
        fail "The files of ${tag} could not be attached."
    for f in checksums.txt "${fa}" "${fb}"; do
        download_of "${tag}" "${f}"
        cmp -s "${got_path}" "${dir}/${f}" || fail "The ${f} attached to ${tag} is not the file of the artifact (SHA-256 $(sum_of "${got_path}"), artifact $(sum_of "${dir}/${f}"))."
    done
    draft=""
    "${GH}" release edit "${tag}" -R "${repo}" --draft=false --latest=false ||
        fail "The draft release ${tag} could not be published: check on the releases page whether it is published or still a draft."
    view_release "${tag}"
    [[ "${state}" == published ]] || fail "${tag} was published, but it reads back as '${state}': check it now."
    check_published "${tag}" "${fa}" "${sa}" "${fb}" "${sb}"
    if latest="$("${GH}" api "repos/${repo}/releases/latest" 2>"${err}")"; then
        latest="$(python3 -I -c 'import json, sys; print(json.loads(sys.argv[1])["tag_name"])' "${latest}")" ||
            fail "${tag} is published, but the latest release of ${repo} cannot be read: check it now."
        [[ "${latest}" != "${tag}" ]] || fail "${tag} is published, but it is the latest release of ${repo}, which a copy must never be: check it now."
    else
        grep -q 'HTTP 404' "${err}" || fail "${tag} is published, but the latest release of ${repo} could not be read: check it now."
    fi
done

echo "mirror.sh: ${#todo[@]} release(s) made in ${repo}, ${there} already there."
