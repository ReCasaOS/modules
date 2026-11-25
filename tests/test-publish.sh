#!/usr/bin/env bash
# Offline tests of scripts/publish.sh. No network: GH is a fake gh (tests/lib/fake-gh) that
# keeps the releases in a folder and writes each call it gets to a log. Needs bash and python3.
#
#   bash tests/test-publish.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

cp "${ROOT}/tests/lib/fake-gh" "${T}/gh"
chmod +x "${T}/gh"

make_out() { # make_out DIR SERIAL [VIRT_TAG] [GENERATED]: catalogue-2.json and catalogue-3.json of one build
    mkdir -p "$1"
    python3 - "$1" "$2" "${3:-v0.2.6}" "${4:-2026-11-25T12:00:00Z}" <<'EOF'
import json, os, sys
out, serial, tag, generated = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
m2 = {"name": "virt", "tag": tag, "commit": "5" * 40, "tier": "core", "manifest": {"name": "virt"},
      "assets": {a: {"url": "https://example.invalid/%s.tar.gz" % a, "sha256": "a" * 64} for a in ("amd64", "arm64")}}
m3 = dict(m2, repository="ReCasaOS/CasaOS-VirtManagement", component="CasaOS-VirtManagement")
m3["assets"] = {a: {"url": "https://github.com/ReCasaOS/modules/releases/download/m-virt-%s/linux-%s-casaos-virt-%s.tar.gz" % (tag, a, tag),
                    "sha256": "a" * 64} for a in ("amd64", "arm64")}
json.dump({"schema": 2, "serial": serial, "generated": generated, "modules": [m2]}, open(os.path.join(out, "catalogue-2.json"), "w"), indent=2)
json.dump({"schema": 3, "serial": serial, "generated": generated, "withdrawn": [], "modules": [m3]}, open(os.path.join(out, "catalogue-3.json"), "w"), indent=2)
EOF
}

reset() { # reset [SERIAL [both]]: a fresh GitHub, with release c<SERIAL> published as latest when given (only catalogue-2.json unless "both")
    rm -rf "${T}/state"
    mkdir -p "${T}/state/rel"
    : >"${T}/state/calls"
    if [[ -n "${1:-}" ]]; then
        make_out "${T}/state/rel/c$1" "$1"
        [[ "${2:-}" == both ]] || rm "${T}/state/rel/c$1/catalogue-3.json"
        printf 'c%s' "$1" >"${T}/state/latest"
    fi
}

run_publish() { # run_publish SERIAL DIR [VAR=value...]: output in ${T}/log
    local serial="$1" dir="$2"
    shift 2
    env GH="${T}/gh" FAKE_GH_STATE="${T}/state" GITHUB_REPOSITORY=ReCasaOS/modules \
        GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 "$@" \
        bash "${ROOT}/scripts/publish.sh" "${serial}" "${dir}" >"${T}/log" 2>&1
}

verbs() { awk '$1 == "api" {print "api"; next} {print $2 ($3 ~ /^c[0-9]+$/ ? " " $3 : "")}' "${T}/state/calls" | paste -sd, -; }
no_write() { ! grep -Eq '^release (create|upload|edit|delete)' "${T}/state/calls"; }
is_draft() { [[ -e "${T}/state/rel/$1/draft" ]]; }
latest() { cat "${T}/state/latest" 2>/dev/null; }
same_files() { cmp -s "${T}/state/rel/$1/catalogue-2.json" "${new}/catalogue-2.json" && cmp -s "${T}/state/rel/$1/catalogue-3.json" "${new}/catalogue-3.json"; }

new="${T}/new"

# 1. first publication of all: nothing published yet is serial 0; the release is made in the order asked, with both files
reset
make_out "${new}" 1
if run_publish 1 "${new}" &&
    [[ "$(verbs)" == "api,api,view c1,create c1,upload c1,download c1,download c1,edit c1,api,download,download" ]] &&
    ! is_draft c1 && [[ "$(latest)" == c1 ]] && same_files c1; then
    pass "first publication: draft, two files, check, publish, read back, in that order"
else
    fail "first publication: draft, two files, check, publish, read back, in that order"; cat "${T}/log" "${T}/state/calls"
fi

# 2. the first publication of schema 3 over a latest release that has only catalogue-2.json (Review Focus 3)
reset 5
rm -rf "${new}"
make_out "${new}" 6 v0.2.7
if run_publish 6 "${new}" && ! is_draft c6 && [[ "$(latest)" == c6 ]] && same_files c6 &&
    [[ "$(verbs)" == "api,download c5,view c6,create c6,upload c6,download c6,download c6,edit c6,api,download,download" ]] &&
    grep -q 'upload c6 .*catalogue-2.json .*catalogue-3.json' "${T}/state/calls"; then
    pass "a serial above the published one, which has no catalogue-3.json, is published with both files as latest"
else
    fail "a serial above the published one, which has no catalogue-3.json, is published with both files as latest"; cat "${T}/log" "${T}/state/calls"
fi
reset 5 both
if run_publish 6 "${new}" && [[ "$(latest)" == c6 ]] && same_files c6; then
    pass "a serial above a published one that has both files is published"
else
    fail "a serial above a published one that has both files is published"; cat "${T}/log" "${T}/state/calls"
fi

# 2b. the latest and the taken are asked through the API and by tag: any number of releases of the mirror
reset 5
for i in $(seq 1 150); do mkdir -p "${T}/state/rel/m-tool$i-v1.0.0"; done
if run_publish 6 "${new}" && [[ "$(latest)" == c6 ]] && ! grep -q '^release list' "${T}/state/calls"; then
    pass "150 other releases do not matter: no listing is read"
else
    fail "150 other releases do not matter: no listing is read"; cat "${T}/log"
fi

# 3. a serial equal to or below the published one: refused, nothing written
for s in 5 4; do
    reset 5
    make_out "${new}" "${s}"
    if ! run_publish "${s}" "${new}" && no_write && grep -q "published serial 5" "${T}/log" && [[ "$(latest)" == c5 ]]; then
        pass "serial ${s} with 5 published is refused, nothing written"
    else
        fail "serial ${s} with 5 published is refused, nothing written"; cat "${T}/log" "${T}/state/calls"
    fi
done

make_out "${new}" 6 # (one more build of serial 6, for what follows)

# 4. an attached file differs from the built one: never published, the draft is left and named
reset 5
if ! run_publish 6 "${new}" FAKE_GH_ALTER_UPLOAD=1 && ! grep -q '^release edit' "${T}/state/calls" &&
    is_draft c6 && [[ "$(latest)" == c5 ]] && grep -q "draft release c6 is left unpublished" "${T}/log"; then
    pass "an attached file that differs is never published; the draft c6 is left and said"
else
    fail "an attached file that differs is never published; the draft c6 is left and said"; cat "${T}/log" "${T}/state/calls"
fi

# 5. a failure after the draft exists (the upload fails) leaves a draft and says so
reset 5
if ! run_publish 6 "${new}" FAKE_GH_FAIL=upload && ! grep -q '^release edit' "${T}/state/calls" &&
    is_draft c6 && [[ "$(latest)" == c5 ]] && grep -q "draft release c6 is left unpublished" "${T}/log"; then
    pass "a failed upload leaves the draft c6 unpublished and says so"
else
    fail "a failed upload leaves the draft c6 unpublished and says so"; cat "${T}/log" "${T}/state/calls"
fi
reset 5
if ! run_publish 6 "${new}" FAKE_GH_FAIL="download c6" && ! grep -q '^release edit' "${T}/state/calls" &&
    is_draft c6 && grep -q "draft release c6 is left unpublished" "${T}/log"; then
    pass "a failed download of the attached files leaves the draft c6 unpublished and says so"
else
    fail "a failed download of the attached files leaves the draft c6 unpublished and says so"; cat "${T}/log" "${T}/state/calls"
fi
reset 5
if ! run_publish 6 "${new}" FAKE_GH_ALTER_DOWNLOAD=1 && ! grep -q '^release edit' "${T}/state/calls" &&
    is_draft c6 && grep -q "draft release c6 is left unpublished" "${T}/log"; then
    pass "a file that comes back from the draft with other bytes is never published"
else
    fail "a file that comes back from the draft with other bytes is never published"; cat "${T}/log" "${T}/state/calls"
fi

# 6. the publish call fails: the state is not known, and that is what is said
reset 5
if ! run_publish 6 "${new}" FAKE_GH_FAIL=edit && grep -q "c6 could not be published" "${T}/log" &&
    ! grep -q "left unpublished" "${T}/log"; then
    pass "a failed publish call says the state of c6 must be checked"
else
    fail "a failed publish call says the state of c6 must be checked"; cat "${T}/log"
fi

# 7. published, but the latest release is not the new one: fails, saying it is published
reset 5
if ! run_publish 6 "${new}" FAKE_GH_NOT_LATEST=1 && grep -q "c6 is published" "${T}/log" && grep -q "c5" "${T}/log"; then
    pass "a latest release that is not c6 fails, saying c6 is published"
else
    fail "a latest release that is not c6 fails, saying c6 is published"; cat "${T}/log"
fi

# 8. the files given are checked before anything is written
reset 5
make_out "${T}/o7" 7
if ! run_publish 6 "${T}/o7" && [[ ! -s "${T}/state/calls" ]] && grep -q "serial 7" "${T}/log"; then
    pass "files whose serial is not SERIAL are refused before any call"
else
    fail "files whose serial is not SERIAL are refused before any call"; cat "${T}/log" "${T}/state/calls"
fi
make_out "${T}/mixed" 6
cp "${T}/o7/catalogue-3.json" "${T}/mixed/catalogue-3.json"
if ! run_publish 6 "${T}/mixed" && [[ ! -s "${T}/state/calls" ]] && grep -q "catalogue-3.json" "${T}/log" && grep -q "serial 7" "${T}/log"; then
    pass "a catalogue-3.json of another serial than the catalogue-2.json is refused before any call"
else
    fail "a catalogue-3.json of another serial than the catalogue-2.json is refused before any call"; cat "${T}/log" "${T}/state/calls"
fi
make_out "${T}/gen" 6 v0.2.6 2026-11-26T08:00:00Z
cp "${T}/gen/catalogue-3.json" "${T}/mixed/catalogue-3.json"
cp "${new}/catalogue-2.json" "${T}/mixed/catalogue-2.json"
if ! run_publish 6 "${T}/mixed" && [[ ! -s "${T}/state/calls" ]] && grep -q "generated" "${T}/log"; then
    pass "two files of one serial but not one generated time are refused before any call"
else
    fail "two files of one serial but not one generated time are refused before any call"; cat "${T}/log" "${T}/state/calls"
fi
printf '<!DOCTYPE html><html><body>Not Found</body></html>\n' >"${T}/html.json"
make_out "${T}/bad2" 6
cp "${T}/html.json" "${T}/bad2/catalogue-2.json"
if ! run_publish 6 "${T}/bad2" && [[ ! -s "${T}/state/calls" ]] && grep -q "not a schema 2 catalogue" "${T}/log"; then
    pass "a catalogue-2.json that is not a schema 2 catalogue is refused before any call"
else
    fail "a catalogue-2.json that is not a schema 2 catalogue is refused before any call"; cat "${T}/log"
fi
make_out "${T}/bad3" 6
cp "${T}/html.json" "${T}/bad3/catalogue-3.json"
if ! run_publish 6 "${T}/bad3" && [[ ! -s "${T}/state/calls" ]] && grep -q "not a schema 3 catalogue" "${T}/log"; then
    pass "a catalogue-3.json that is not a schema 3 catalogue is refused before any call"
else
    fail "a catalogue-3.json that is not a schema 3 catalogue is refused before any call"; cat "${T}/log"
fi
make_out "${T}/only2" 6
rm "${T}/only2/catalogue-3.json"
if ! run_publish 6 "${T}/only2" && [[ ! -s "${T}/state/calls" ]]; then
    pass "a catalogue-3.json that is missing is refused before any call"
else
    fail "a catalogue-3.json that is missing is refused before any call"; cat "${T}/log" "${T}/state/calls"
fi

# 9. the published serial is read or nothing is written: never taken as 0 on a failure
reset 5
if ! run_publish 6 "${new}" FAKE_GH_FAIL=api && no_write; then
    pass "a latest release that cannot be read: refused, nothing written"
else
    fail "a latest release that cannot be read: refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi
reset 5
rm "${T}/state/rel/c5/catalogue-2.json"
if ! run_publish 6 "${new}" && no_write && grep -q "c5" "${T}/log"; then
    pass "a latest release without catalogue-2.json: refused, nothing written"
else
    fail "a latest release without catalogue-2.json: refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi
reset 5
cp "${T}/html.json" "${T}/state/rel/c5/catalogue-2.json"
if ! run_publish 6 "${new}" && no_write && grep -q "not a schema 2 catalogue" "${T}/log"; then
    pass "a published file that is not a catalogue: refused, nothing written"
else
    fail "a published file that is not a catalogue: refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi
reset 5
rm "${T}/state/latest"
if ! run_publish 6 "${new}" && no_write; then
    pass "releases but none latest (a 404 while a release exists): refused, nothing written"
else
    fail "releases but none latest (a 404 while a release exists): refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi

# 10. a release c<SERIAL> already there (a draft of an earlier attempt of the same run): refused, named
reset 5
mkdir -p "${T}/state/rel/c6" && : >"${T}/state/rel/c6/draft"
if ! run_publish 6 "${new}" && no_write && grep -q "c6 already exists" "${T}/log"; then
    pass "a release c6 that already exists (a draft) is refused, nothing written"
else
    fail "a release c6 that already exists (a draft) is refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi
reset 5
if ! run_publish 6 "${new}" FAKE_GH_FAIL="view c6" && no_write; then
    pass "a release c6 that cannot be looked up is not read as absent: refused, nothing written"
else
    fail "a release c6 that cannot be looked up is not read as absent: refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi

# 11. only ReCasaOS/modules, unless the test variable says otherwise (and then it is said)
reset 5
if ! run_publish 6 "${new}" GITHUB_REPOSITORY=someone/modules && [[ ! -s "${T}/state/calls" ]] && grep -q "ReCasaOS/modules" "${T}/log"; then
    pass "another repository is refused before any call"
else
    fail "another repository is refused before any call"; cat "${T}/log"
fi
reset 5
if run_publish 6 "${new}" GITHUB_REPOSITORY=someone/modules MODULES_TEST_REPOSITORY=someone/modules &&
    grep -q "test only" "${T}/log" && grep -q -- "-R someone/modules" "${T}/state/calls" && grep -q "repos/someone/modules/releases/latest" "${T}/state/calls"; then
    pass "MODULES_TEST_REPOSITORY allows another repository, and says so"
else
    fail "MODULES_TEST_REPOSITORY allows another repository, and says so"; cat "${T}/log"
fi

# 12. a published serial at or above 2^63 is not a catalogue, and a huge one is still compared as a number
reset 9223372036854775808
make_out "${T}/o5" 5
if ! run_publish 5 "${T}/o5" && no_write && grep -q "not a schema 2 catalogue" "${T}/log" && [[ "$(latest)" == c9223372036854775808 ]]; then
    pass "a published serial of 2^63 is refused, nothing written"
else
    fail "a published serial of 2^63 is refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi
reset 9223372036854775806
if ! run_publish 5 "${T}/o5" && no_write && grep -q "published serial 9223372036854775806" "${T}/log"; then
    pass "serial 5 with 9223372036854775806 published is refused as not above, nothing written"
else
    fail "serial 5 with 9223372036854775806 published is refused as not above, nothing written"; cat "${T}/log" "${T}/state/calls"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL: ${failures} test(s)"
    exit 1
fi
