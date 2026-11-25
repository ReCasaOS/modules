#!/usr/bin/env bash
# Offline tests of scripts/mirror.sh. No network: GH is a fake gh (tests/lib/fake-gh) that
# keeps the releases in a folder and writes each call it gets to a log. Needs bash and python3.
#
#   bash tests/test-mirror.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

cp "${ROOT}/tests/lib/fake-gh" "${T}/gh"
chmod +x "${T}/gh"

ALICE=m-alice-tool-v0.1.0 # a module of another owner
VIRT=m-virt-v0.2.6        # a module of ReCasaOS

make_out() { # make_out DIR: what scripts/build.sh writes for two modules, and the modules.env that pins the one of another owner
    python3 - "$1" "${T}/modules.env" <<'EOF'
import hashlib, json, os, sys
out, env = sys.argv[1:]
mods = [("alice-tool", "v0.1.0", "alice/CasaOS-alice-tool", "community"), ("virt", "v0.2.6", "ReCasaOS/CasaOS-VirtManagement", "core")]
entries, lines = [], []
for name, tag, repository, tier in mods:
    assets, sums = {}, []
    up = name.upper().replace("-", "_")
    lines += ["MODULE_%s_TAG=%s" % (up, tag), "MODULE_%s_COMPONENT=%s" % (up, repository.split("/")[1])]
    if not repository.startswith("ReCasaOS/"):
        lines.append("MODULE_%s_OWNER=%s" % (up, repository.split("/")[0]))
    d = os.path.join(out, "mirror", "m-%s-%s" % (name, tag))
    os.makedirs(d)
    for arch in ("amd64", "arm64"):
        file = "linux-%s-casaos-%s-%s.tar.gz" % (arch, name, tag)
        data = ("archive of %s %s %s\n" % (name, tag, arch)).encode()
        open(os.path.join(d, file), "wb").write(data)
        sha = hashlib.sha256(data).hexdigest()
        sums.append("%s  %s\n" % (sha, file))
        assets[arch] = {"url": "https://github.com/ReCasaOS/modules/releases/download/m-%s-%s/%s" % (name, tag, file), "sha256": sha}
        if not repository.startswith("ReCasaOS/"):
            lines.append("MODULE_%s_SHA256_%s=%s" % (name.upper().replace("-", "_"), arch.upper(), sha))
    open(os.path.join(d, "checksums.txt"), "w").write("".join(sums))
    entries.append({"name": name, "tag": tag, "commit": "5" * 40, "tier": tier, "manifest": {"name": name}, "repository": repository,
                    "component": repository.split("/")[1], "assets": assets})
json.dump({"schema": 3, "serial": 7, "generated": "2026-11-25T12:00:00Z", "withdrawn": [], "modules": entries}, open(os.path.join(out, "catalogue-3.json"), "w"), indent=2)
open(env, "w").write("\n".join(lines) + "\n")
EOF
}

reset() { # reset: a fresh GitHub whose latest release is c3, with catalogue-2.json only; a fresh build in ${T}/out
    rm -rf "${T}/state" "${T}/out"
    mkdir -p "${T}/state/rel/c3"
    : >"${T}/state/calls"
    echo '{}' >"${T}/state/rel/c3/catalogue-2.json"
    printf c3 >"${T}/state/latest"
    make_out "${T}/out"
}

carry() { mv "${T}/out/mirror/$1" "${T}/state/rel/$1"; } # carry TAG: that release is already published here, so the build did not fetch it again

run_mirror() { # run_mirror [VAR=value...]: output in ${T}/log
    env GH="${T}/gh" FAKE_GH_STATE="${T}/state" GITHUB_REPOSITORY=ReCasaOS/modules MODULES_TEST_ENV_FILE="${T}/modules.env" \
        GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 "$@" \
        bash "${ROOT}/scripts/mirror.sh" "${T}/out" >"${T}/log" 2>&1
}

verbs() { awk '$1 == "api" {print "api"; next} {print $2 ($3 ~ /^(c[0-9]+|m-.*)$/ ? " " $3 : "")}' "${T}/state/calls" | paste -sd, -; }
no_write() { ! grep -Eq '^release (create|upload|edit|delete)' "${T}/state/calls"; }
is_draft() { [[ -e "${T}/state/rel/$1/draft" ]]; }
files() { ls "${T}/state/rel/$1" | paste -sd' ' -; }
holds() { # holds TAG: the release is published as the mirror build has it, with the same bytes
    [[ -d "${T}/state/rel/$1" ]] && ! is_draft "$1" && [[ "$(files "$1")" == "$(ls "${T}/saved/$1" | paste -sd' ' -)" ]] &&
        diff -r "${T}/saved/$1" "${T}/state/rel/$1" >/dev/null
}
save() { rm -rf "${T}/saved"; cp -r "${T}/out/mirror" "${T}/saved"; } # the files of the build, kept to compare with what was published

# 1. nothing published: every release is looked up first, then each one is made in the order asked
reset
save
if run_mirror &&
    [[ "$(verbs)" == "view ${ALICE},view ${VIRT},create ${ALICE},upload ${ALICE},download ${ALICE},download ${ALICE},download ${ALICE},edit ${ALICE},view ${ALICE},api,create ${VIRT},upload ${VIRT},download ${VIRT},download ${VIRT},download ${VIRT},edit ${VIRT},view ${VIRT},api" ]] &&
    holds "${ALICE}" && holds "${VIRT}" && [[ "$(cat "${T}/state/latest")" == c3 ]]; then
    pass "two missing mirrors: all looked up, then each one draft, files, read back, publish, check; latest stays c3"
else
    fail "two missing mirrors: all looked up, then each one draft, files, read back, publish, check; latest stays c3"; cat "${T}/log" "${T}/state/calls"
fi
if grep -q "^release create ${ALICE} -R ReCasaOS/modules --draft --target 0123456789abcdef0123456789abcdef01234567 " "${T}/state/calls" &&
    grep -qF "release edit ${ALICE} -R ReCasaOS/modules --draft=false --latest=false" "${T}/state/calls" &&
    grep -q "^release upload ${ALICE} .*checksums.txt .*linux-amd64-casaos-alice-tool-v0.1.0.tar.gz .*linux-arm64-casaos-alice-tool-v0.1.0.tar.gz" "${T}/state/calls"; then
    pass "a mirror is a draft on GITHUB_SHA with its three files, published with --latest=false"
else
    fail "a mirror is a draft on GITHUB_SHA with its three files, published with --latest=false"; cat "${T}/state/calls"
fi

# 2. a published release that is as the catalogue says: no write call at all
reset
carry "${ALICE}"
carry "${VIRT}"
if run_mirror && no_write && [[ "$(verbs)" == "view ${ALICE},view ${VIRT}" ]]; then
    pass "published releases that are as the catalogue says: two lookups, nothing written"
else
    fail "published releases that are as the catalogue says: two lookups, nothing written"; cat "${T}/log" "${T}/state/calls"
fi
reset
carry "${ALICE}"
touch "${T}/state/rel/${ALICE}/nodigest"
if run_mirror && grep -q "^release download ${ALICE} .*--pattern linux-amd64" "${T}/state/calls" && grep -q "^release download ${ALICE} .*--pattern linux-arm64" "${T}/state/calls" &&
    ! grep -Eq "^release (create|upload|edit) ${ALICE}" "${T}/state/calls"; then
    pass "a published release whose API gives no digest: the archives are downloaded and hashed"
else
    fail "a published release whose API gives no digest: the archives are downloaded and hashed"; cat "${T}/log" "${T}/state/calls"
fi

# 3. a published release with other bytes than the catalogue's (Review Focus 2): stop, nothing created, said
reset
carry "${ALICE}"
echo other >"${T}/state/rel/${ALICE}/linux-arm64-casaos-alice-tool-v0.1.0.tar.gz"
if ! run_mirror && no_write && grep -q "${ALICE}" "${T}/log" && grep -q "linux-arm64-casaos-alice-tool-v0.1.0.tar.gz" "${T}/log"; then
    pass "a published release with another SHA-256 stops the run before any creation, naming it"
else
    fail "a published release with another SHA-256 stops the run before any creation, naming it"; cat "${T}/log" "${T}/state/calls"
fi
touch "${T}/state/rel/${ALICE}/nodigest"
if ! run_mirror && no_write && grep -q "${ALICE}" "${T}/log"; then
    pass "the same with no digest from the API: found by downloading"
else
    fail "the same with no digest from the API: found by downloading"; cat "${T}/log" "${T}/state/calls"
fi
reset
carry "${ALICE}"
rm "${T}/state/rel/${ALICE}/checksums.txt"
if ! run_mirror && no_write && grep -q "checksums.txt" "${T}/log"; then
    pass "a published release without one of its three files stops the run"
else
    fail "a published release without one of its three files stops the run"; cat "${T}/log" "${T}/state/calls"
fi
reset
carry "${ALICE}"
echo extra >"${T}/state/rel/${ALICE}/extra.txt"
if ! run_mirror && no_write && grep -q "extra.txt" "${T}/log"; then
    pass "a published release with a fourth file stops the run"
else
    fail "a published release with a fourth file stops the run"; cat "${T}/log" "${T}/state/calls"
fi

# 4. a draft left by an earlier try: stop, even when another mirror is missing, and nothing is created or deleted
reset
carry "${VIRT}"
: >"${T}/state/rel/${VIRT}/draft"
if ! run_mirror && no_write && grep -q "delete the draft ${VIRT} and run again" "${T}/log"; then
    pass "a draft mirror release stops the run, whatever else is missing: delete the draft and run again"
else
    fail "a draft mirror release stops the run, whatever else is missing: delete the draft and run again"; cat "${T}/log" "${T}/state/calls"
fi

# 5. an archive of the artifact that is not the one of the catalogue: nothing is created, for either module
reset
echo altered >>"${T}/out/mirror/${VIRT}/linux-amd64-casaos-virt-v0.2.6.tar.gz"
if ! run_mirror && no_write && grep -q "linux-amd64-casaos-virt-v0.2.6.tar.gz" "${T}/log" && grep -q "SHA-256" "${T}/log" && [[ "$(verbs)" == "view ${ALICE},view ${VIRT}" ]]; then
    pass "an archive altered in the artifact stops the run before any creation (the other module included)"
else
    fail "an archive altered in the artifact stops the run before any creation (the other module included)"; cat "${T}/log" "${T}/state/calls"
fi

# 6. a module of another owner whose archive is not the one modules.env pins
reset
sed -i 's/^\(MODULE_ALICE_TOOL_SHA256_ARM64=\).*/\1'"$(printf 'b%.0s' $(seq 1 64))"'/' "${T}/modules.env"
if ! run_mirror && no_write && grep -q "modules.env" "${T}/log" && grep -q "arm64" "${T}/log"; then
    pass "an archive of another owner that is not the one modules.env pins stops the run before any creation"
else
    fail "an archive of another owner that is not the one modules.env pins stops the run before any creation"; cat "${T}/log" "${T}/state/calls"
fi
reset
sed -i '/^MODULE_ALICE_TOOL_SHA256_AMD64=/d' "${T}/modules.env"
if ! run_mirror && no_write && grep -q "modules.env" "${T}/log"; then
    pass "a module of another owner with no pinned line stops the run"
else
    fail "a module of another owner with no pinned line stops the run"; cat "${T}/log" "${T}/state/calls"
fi
reset
grep '^MODULE_ALICE_TOOL_SHA256_AMD64=' "${T}/modules.env" >"${T}/twice" && cat "${T}/twice" >>"${T}/modules.env"
if ! run_mirror && no_write && grep -q "modules.env" "${T}/log"; then
    pass "a pinned line that appears twice stops the run"
else
    fail "a pinned line that appears twice stops the run"; cat "${T}/log" "${T}/state/calls"
fi
reset
sed -i 's/^MODULE_ALICE_TOOL_SHA256_AMD64=\(.*\)/MODULE_ALICE_TOOL_SHA256_AMD64=\U\1/' "${T}/modules.env"
if ! run_mirror && no_write && grep -q "modules.env" "${T}/log"; then
    pass "a pinned line that is not 64 lower case hexadecimal digits stops the run"
else
    fail "a pinned line that is not 64 lower case hexadecimal digits stops the run"; cat "${T}/log" "${T}/state/calls"
fi

# 7. an entry with no release and no folder in the artifact; a folder with no entry; a checksums.txt that does not say the sums
reset
rm -rf "${T}/out/mirror/${VIRT}"
if ! run_mirror && no_write && grep -q "${VIRT}" "${T}/log"; then
    pass "an entry carried over with no release here stops the run"
else
    fail "an entry carried over with no release here stops the run"; cat "${T}/log" "${T}/state/calls"
fi
reset
cp -r "${T}/out/mirror/${VIRT}" "${T}/out/mirror/m-ghost-v1.0.0"
if ! run_mirror && no_write && grep -q "m-ghost-v1.0.0" "${T}/log"; then
    pass "a folder of the artifact that no entry names stops the run"
else
    fail "a folder of the artifact that no entry names stops the run"; cat "${T}/log" "${T}/state/calls"
fi
reset
head -n 1 "${T}/out/mirror/${VIRT}/checksums.txt" >"${T}/one" && cp "${T}/one" "${T}/out/mirror/${VIRT}/checksums.txt"
if ! run_mirror && no_write && grep -q "checksums.txt" "${T}/log"; then
    pass "a checksums.txt that lacks the line of an archive stops the run"
else
    fail "a checksums.txt that lacks the line of an archive stops the run"; cat "${T}/log" "${T}/state/calls"
fi
reset
echo extra >"${T}/out/mirror/${VIRT}/notes.txt"
if ! run_mirror && no_write && grep -q "notes.txt" "${T}/log"; then
    pass "a folder with a file that is not one of the three stops the run"
else
    fail "a folder with a file that is not one of the three stops the run"; cat "${T}/log" "${T}/state/calls"
fi

# 8. failures after a draft exists name the draft, and nothing is published after them
reset
if ! run_mirror FAKE_GH_ALTER_DOWNLOAD=1 && ! grep -q '^release edit' "${T}/state/calls" && is_draft "${ALICE}" &&
    grep -q "the draft release ${ALICE} is left unpublished" "${T}/log" && ! grep -q "release create ${VIRT}" "${T}/state/calls"; then
    pass "a file that comes back from the draft with other bytes is never published; the draft is named; the next mirror is not started"
else
    fail "a file that comes back from the draft with other bytes is never published; the draft is named; the next mirror is not started"; cat "${T}/log" "${T}/state/calls"
fi
reset
if ! run_mirror FAKE_GH_ALTER_UPLOAD=1 && ! grep -q '^release edit' "${T}/state/calls" && is_draft "${ALICE}" && grep -q "the draft release ${ALICE} is left unpublished" "${T}/log"; then
    pass "an attached file that differs is never published; the draft is named"
else
    fail "an attached file that differs is never published; the draft is named"; cat "${T}/log" "${T}/state/calls"
fi
reset
if ! run_mirror FAKE_GH_FAIL=upload && is_draft "${ALICE}" && grep -q "the draft release ${ALICE} is left unpublished" "${T}/log"; then
    pass "a failed upload names the draft that is left"
else
    fail "a failed upload names the draft that is left"; cat "${T}/log" "${T}/state/calls"
fi
reset
if ! run_mirror FAKE_GH_FAIL=edit && grep -q "${ALICE} could not be published" "${T}/log"; then
    pass "a failed publish call says the state of the release must be checked"
else
    fail "a failed publish call says the state of the release must be checked"; cat "${T}/log"
fi
reset
if ! run_mirror FAKE_GH_EDIT_LATEST=1 && grep -q "${ALICE} is published" "${T}/log" && grep -q "latest" "${T}/log"; then
    pass "a mirror release that turns out to be the latest release fails, saying it is published"
else
    fail "a mirror release that turns out to be the latest release fails, saying it is published"; cat "${T}/log" "${T}/state/calls"
fi

# 9. a lookup that fails is not an absent release
reset
if ! run_mirror FAKE_GH_FAIL=view && no_write && grep -q "could not be read" "${T}/log"; then
    pass "a release that cannot be looked up is not read as absent: nothing created"
else
    fail "a release that cannot be looked up is not read as absent: nothing created"; cat "${T}/log" "${T}/state/calls"
fi

# 10. the guards of publish.sh
reset
if ! run_mirror GITHUB_REPOSITORY=someone/modules && [[ ! -s "${T}/state/calls" ]] && grep -q "ReCasaOS/modules" "${T}/log"; then
    pass "another repository is refused before any call"
else
    fail "another repository is refused before any call"; cat "${T}/log"
fi
reset
if ! run_mirror GITHUB_SHA=main && [[ ! -s "${T}/state/calls" ]]; then
    pass "a GITHUB_SHA that is not a full commit is refused before any call"
else
    fail "a GITHUB_SHA that is not a full commit is refused before any call"; cat "${T}/log"
fi
reset
cp "${T}/out/catalogue-3.json" "${T}/c3.json"
echo '{"schema": 3}' >"${T}/out/catalogue-3.json"
if ! run_mirror && [[ ! -s "${T}/state/calls" ]] && grep -q "not a schema 3 catalogue" "${T}/log"; then
    pass "a catalogue-3.json that is not a schema 3 catalogue is refused before any call"
else
    fail "a catalogue-3.json that is not a schema 3 catalogue is refused before any call"; cat "${T}/log"
fi

# 11. the entries are bound to modules.env, which this job reads itself, not to what the build job says of them
reset
python3 - "${T}/out/catalogue-3.json" <<'EOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
for e in c["modules"]:
    if e["name"] == "alice-tool":
        e["repository"] = "ReCasaOS/" + e["component"]
json.dump(c, open(p, "w"))
EOF
if ! run_mirror && no_write && grep -q "alice-tool" "${T}/log" && grep -q "repository" "${T}/log"; then
    pass "an entry that relabels a module pinned in modules.env as ReCasaOS's is refused, nothing created"
else
    fail "an entry that relabels a module pinned in modules.env as ReCasaOS's is refused, nothing created"; cat "${T}/log" "${T}/state/calls"
fi
reset
sed -i '/^MODULE_ALICE_TOOL_/d' "${T}/modules.env"
if ! run_mirror && no_write && grep -q "alice-tool, which modules.env does not list" "${T}/log"; then
    pass "an entry that modules.env does not list is refused, nothing created"
else
    fail "an entry that modules.env does not list is refused, nothing created"; cat "${T}/log" "${T}/state/calls"
fi
reset
sed -i 's/^MODULE_VIRT_TAG=.*/MODULE_VIRT_TAG=v0.2.7/' "${T}/modules.env"
if ! run_mirror && no_write && grep -q "virt at v0.2.6" "${T}/log"; then
    pass "an entry at another tag than modules.env lists is refused, nothing created"
else
    fail "an entry at another tag than modules.env lists is refused, nothing created"; cat "${T}/log" "${T}/state/calls"
fi
reset
printf 'MODULE_BOB_TAG=v1.0.0\n' >>"${T}/modules.env"
if ! run_mirror && no_write && grep -q "lists the module bob" "${T}/log"; then
    pass "a module of modules.env that the catalogue lacks is refused, nothing created"
else
    fail "a module of modules.env that the catalogue lacks is refused, nothing created"; cat "${T}/log" "${T}/state/calls"
fi
reset
sed -i 's/^MODULE_VIRT_COMPONENT=.*/MODULE_VIRT_COMPONENT=Other/' "${T}/modules.env"
if ! run_mirror && no_write && grep -q "component" "${T}/log"; then
    pass "an entry of another component than modules.env lists is refused, nothing created"
else
    fail "an entry of another component than modules.env lists is refused, nothing created"; cat "${T}/log" "${T}/state/calls"
fi
reset
carry "${ALICE}"
sed -i 's/^\(MODULE_ALICE_TOOL_SHA256_AMD64=\).*/\1'"$(printf 'c%.0s' $(seq 1 64))"'/' "${T}/modules.env"
if ! run_mirror && no_write && grep -q "modules.env pins" "${T}/log"; then
    pass "a carried entry whose sums are not the pinned ones is refused too"
else
    fail "a carried entry whose sums are not the pinned ones is refused too"; cat "${T}/log" "${T}/state/calls"
fi

# 12. checksums.txt names each archive once
reset
printf '%s  linux-amd64-casaos-virt-v0.2.6.tar.gz\n' "$(printf 'd%.0s' $(seq 1 64))" >>"${T}/out/mirror/${VIRT}/checksums.txt"
if ! run_mirror && no_write && grep -q "more than one line" "${T}/log"; then
    pass "a checksums.txt that gives a second sum for an archive stops the run"
else
    fail "a checksums.txt that gives a second sum for an archive stops the run"; cat "${T}/log" "${T}/state/calls"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL: ${failures} test(s)"
    exit 1
fi
