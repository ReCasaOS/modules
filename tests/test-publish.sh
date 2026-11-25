#!/usr/bin/env bash
# Offline tests of scripts/publish.sh. No network: GH is a fake gh that keeps
# the releases in a folder and writes each call it gets to a log. Needs bash
# and python3.
#
#   bash tests/test-publish.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# --- the fake gh: the release subcommands publish.sh uses ------------------
# State in FAKE_GH_STATE: rel/<tag>/ per release (a file 'draft' while it is one, its assets), 'latest' (a tag), 'calls'.
# FAKE_GH_FAIL="<subcommand>" or "<subcommand> <tag>" fails that call; FAKE_GH_ALTER_UPLOAD=1 stores other bytes than
# the file uploaded; FAKE_GH_NOT_LATEST=1 publishes a draft without making it the latest.
cat >"${T}/gh" <<'EOF'
#!/usr/bin/env python3
import json, os, shutil, sys
S = os.environ["FAKE_GH_STATE"]
a = sys.argv[1:]
with open(os.path.join(S, "calls"), "a") as f:
    f.write(" ".join(a) + "\n")
rel = os.path.join(S, "rel")
os.makedirs(rel, exist_ok=True)
latest_file = os.path.join(S, "latest")
latest = open(latest_file).read() if os.path.exists(latest_file) else None

def opt(name):
    return a[a.index(name) + 1]

assert a[0] == "release" and opt("-R"), a
cmd = a[1]
tag = a[2] if len(a) > 2 and not a[2].startswith("-") else None
if os.environ.get("FAKE_GH_FAIL") in (cmd, "%s %s" % (cmd, tag)):
    sys.exit("fake gh: HTTP 502")
if cmd == "list":
    assert opt("--json") == "tagName,isDraft,isLatest", a
    print(json.dumps([{"tagName": t, "isDraft": os.path.exists(os.path.join(rel, t, "draft")), "isLatest": t == latest}
                      for t in sorted(os.listdir(rel))]))
elif cmd == "download":
    tag = tag or latest
    if tag is None or not os.path.isdir(os.path.join(rel, tag)):
        sys.exit("release not found")
    src = os.path.join(rel, tag, opt("--pattern"))
    if not os.path.exists(src):
        sys.exit("no assets match the file pattern")
    dst = os.path.join(opt("--dir"), os.path.basename(src))
    if os.path.exists(dst):
        sys.exit("%s already exists" % dst)
    shutil.copy(src, dst)
elif cmd == "create":
    assert "--draft" in a and len(opt("--target")) == 40, a
    os.makedirs(os.path.join(rel, tag))
    open(os.path.join(rel, tag, "draft"), "w").close()
elif cmd == "upload":
    data = open(a[3], "rb").read()
    if os.environ.get("FAKE_GH_ALTER_UPLOAD"):
        data += b" "
    open(os.path.join(rel, tag, os.path.basename(a[3])), "wb").write(data)
elif cmd == "edit":
    assert "--draft=false" in a and "--latest" in a, a
    os.remove(os.path.join(rel, tag, "draft"))
    if not os.environ.get("FAKE_GH_NOT_LATEST"):
        open(latest_file, "w").write(tag)
else:
    sys.exit("fake gh: unexpected call %s" % a)
EOF
chmod +x "${T}/gh"

catalogue() { # catalogue FILE SERIAL [VIRT_TAG]: a schema 2 catalogue
    python3 - "$1" "$2" "${3:-v0.2.6}" <<'EOF'
import json, sys
m = {"name": "virt", "tag": sys.argv[3], "commit": "5" * 40, "tier": "core", "manifest": {"name": "virt"},
     "assets": {a: {"url": "https://example.invalid/%s.tar.gz" % a, "sha256": "a" * 64} for a in ("amd64", "arm64")}}
json.dump({"schema": 2, "serial": int(sys.argv[2]), "generated": "2026-11-25T12:00:00Z", "modules": [m]}, open(sys.argv[1], "w"), indent=2)
EOF
}

reset() { # reset [SERIAL]: a fresh GitHub, with release c<SERIAL> published as latest when given
    rm -rf "${T}/state"
    mkdir -p "${T}/state/rel"
    : >"${T}/state/calls"
    if [[ -n "${1:-}" ]]; then
        mkdir -p "${T}/state/rel/c$1"
        catalogue "${T}/state/rel/c$1/catalogue-2.json" "$1"
        printf 'c%s' "$1" >"${T}/state/latest"
    fi
}

run_publish() { # run_publish SERIAL FILE [VAR=value...]: output in ${T}/log
    local serial="$1" file="$2"
    shift 2
    env GH="${T}/gh" FAKE_GH_STATE="${T}/state" GITHUB_REPOSITORY=ReCasaOS/modules \
        GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 "$@" \
        bash "${ROOT}/scripts/publish.sh" "${serial}" "${file}" >"${T}/log" 2>&1
}

verbs() { awk '{print $2 ($3 ~ /^c[0-9]+$/ ? " " $3 : "")}' "${T}/state/calls" | paste -sd, -; }
no_write() { ! grep -Eq '^release (create|upload|edit|delete)' "${T}/state/calls"; }
is_draft() { [[ -e "${T}/state/rel/$1/draft" ]]; }
latest() { cat "${T}/state/latest" 2>/dev/null; }

new="${T}/new.json"

# 1. first publication: nothing published yet is serial 0, the release is made in the order asked
reset
catalogue "${new}" 1
if run_publish 1 "${new}" &&
    [[ "$(verbs)" == "list,create c1,upload c1,download c1,edit c1,download" ]] &&
    ! is_draft c1 && [[ "$(latest)" == c1 ]] && cmp -s "${T}/state/rel/c1/catalogue-2.json" "${new}"; then
    pass "first publication: draft, file, check, publish, read back, in that order"
else
    fail "first publication: draft, file, check, publish, read back, in that order"; cat "${T}/log" "${T}/state/calls"
fi

# 2. a serial above the published one passes
reset 5
catalogue "${new}" 6 v0.2.7
if run_publish 6 "${new}" && ! is_draft c6 && [[ "$(latest)" == c6 ]] &&
    [[ "$(verbs)" == "list,download c5,create c6,upload c6,download c6,edit c6,download" ]]; then
    pass "a serial above the published one is published as latest"
else
    fail "a serial above the published one is published as latest"; cat "${T}/log" "${T}/state/calls"
fi

# 3. a serial equal to or below the published one: refused, nothing written
for s in 5 4; do
    reset 5
    catalogue "${new}" "${s}"
    if ! run_publish "${s}" "${new}" && no_write && grep -q "published serial 5" "${T}/log" && [[ "$(latest)" == c5 ]]; then
        pass "serial ${s} with 5 published is refused, nothing written"
    else
        fail "serial ${s} with 5 published is refused, nothing written"; cat "${T}/log" "${T}/state/calls"
    fi
done

# 4. the attached file differs from the built one: never published, the draft is left and named
reset 5
catalogue "${new}" 6
if ! run_publish 6 "${new}" FAKE_GH_ALTER_UPLOAD=1 && ! grep -q '^release edit' "${T}/state/calls" &&
    is_draft c6 && [[ "$(latest)" == c5 ]] && grep -q "draft release c6 is left unpublished" "${T}/log"; then
    pass "an attached file that differs is never published; the draft c6 is left and said"
else
    fail "an attached file that differs is never published; the draft c6 is left and said"; cat "${T}/log" "${T}/state/calls"
fi

# 5. a failure after the draft exists (the upload fails) leaves a draft and says so
reset 5
catalogue "${new}" 6
if ! run_publish 6 "${new}" FAKE_GH_FAIL=upload && ! grep -q '^release edit' "${T}/state/calls" &&
    is_draft c6 && [[ "$(latest)" == c5 ]] && grep -q "draft release c6 is left unpublished" "${T}/log"; then
    pass "a failed upload leaves the draft c6 unpublished and says so"
else
    fail "a failed upload leaves the draft c6 unpublished and says so"; cat "${T}/log" "${T}/state/calls"
fi
reset 5
if ! run_publish 6 "${new}" FAKE_GH_FAIL="download c6" && ! grep -q '^release edit' "${T}/state/calls" &&
    is_draft c6 && grep -q "draft release c6 is left unpublished" "${T}/log"; then
    pass "a failed download of the attached file leaves the draft c6 unpublished and says so"
else
    fail "a failed download of the attached file leaves the draft c6 unpublished and says so"; cat "${T}/log" "${T}/state/calls"
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
if ! run_publish 6 "${new}" FAKE_GH_NOT_LATEST=1 && grep -q "c6 is published" "${T}/log"; then
    pass "a latest address that serves another file fails, saying c6 is published"
else
    fail "a latest address that serves another file fails, saying c6 is published"; cat "${T}/log"
fi

# 8. the file given is checked before anything is written
reset 5
catalogue "${new}" 7
if ! run_publish 6 "${new}" && [[ ! -s "${T}/state/calls" ]] && grep -q "serial 7" "${T}/log"; then
    pass "a file whose serial is not SERIAL is refused before any call"
else
    fail "a file whose serial is not SERIAL is refused before any call"; cat "${T}/log" "${T}/state/calls"
fi
printf '<!DOCTYPE html><html><body>Not Found</body></html>\n' >"${T}/html.json"
if ! run_publish 6 "${T}/html.json" && [[ ! -s "${T}/state/calls" ]] && grep -q "not a schema 2 catalogue" "${T}/log"; then
    pass "a file that is not a schema 2 catalogue is refused before any call"
else
    fail "a file that is not a schema 2 catalogue is refused before any call"; cat "${T}/log"
fi

# 9. the published serial is read or nothing is written: never taken as 0 on a failure
reset 5
catalogue "${new}" 6
if ! run_publish 6 "${new}" FAKE_GH_FAIL=list && no_write; then
    pass "releases that cannot be listed: refused, nothing written"
else
    fail "releases that cannot be listed: refused, nothing written"; cat "${T}/log" "${T}/state/calls"
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
    pass "published releases but none is latest: refused, nothing written"
else
    fail "published releases but none is latest: refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi

# 10. a release c<SERIAL> already there (a draft of an earlier attempt of the same run): refused, named
reset 5
mkdir -p "${T}/state/rel/c6" && : >"${T}/state/rel/c6/draft"
if ! run_publish 6 "${new}" && no_write && grep -q "c6 already exists" "${T}/log"; then
    pass "a release c6 that already exists (a draft) is refused, nothing written"
else
    fail "a release c6 that already exists (a draft) is refused, nothing written"; cat "${T}/log" "${T}/state/calls"
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
    grep -q "test only" "${T}/log" && grep -q -- "-R someone/modules" "${T}/state/calls"; then
    pass "MODULES_TEST_REPOSITORY allows another repository, and says so"
else
    fail "MODULES_TEST_REPOSITORY allows another repository, and says so"; cat "${T}/log"
fi

# 12. a published serial at or above 2^63 is not a catalogue, and a huge one is still compared as a number
reset 9223372036854775808
catalogue "${new}" 5
if ! run_publish 5 "${new}" && no_write && grep -q "not a schema 2 catalogue" "${T}/log" && [[ "$(latest)" == c9223372036854775808 ]]; then
    pass "a published serial of 2^63 is refused, nothing written"
else
    fail "a published serial of 2^63 is refused, nothing written"; cat "${T}/log" "${T}/state/calls"
fi
reset 9223372036854775806
if ! run_publish 5 "${new}" && no_write && grep -q "published serial 9223372036854775806" "${T}/log"; then
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
