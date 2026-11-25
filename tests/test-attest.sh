#!/usr/bin/env bash
# Offline tests of scripts/attest.sh. No network: GH is a fake gh that notes its arguments and fails on the archive named by FAKE_GH_FAIL_ON.
# They prove the arguments, their order, the validation before any call and the failure handling; the real verification of an attestation is not proven here.
# Needs bash.
#
#   bash tests/test-attest.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

cat >"${T}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${FAKE_GH_CALLS}"; printf -- '--\n' >>"${FAKE_GH_CALLS}"
if [[ "$3" == "${FAKE_GH_FAIL_ON:-}" ]]; then
    printf 'no attestations found\nfor subject\n' >&2
    exit 1
fi
EOF
chmod +x "${T}/gh"
export GH="${T}/gh" FAKE_GH_CALLS="${T}/calls"

COMMIT="$(printf 'a%.0s' {1..40})"
echo one >"${T}/one.tar.gz"
echo two >"${T}/two.tar.gz"

run() { # run ARGS...: stdout and stderr to ${T}/out, status in ${status}
    : >"${FAKE_GH_CALLS}"
    bash "${ROOT}/scripts/attest.sh" "$@" >"${T}/out" 2>&1
    status=$?
}

run alice/CasaOS-foo v0.1.2 "${COMMIT}" "${T}/one.tar.gz" "${T}/two.tar.gz"
expect() { printf '%s
' attestation verify "$1" --repo "$2" --source-digest "${COMMIT}" --source-ref "refs/tags/$3" --deny-self-hosted-runners --; }
calls() { grep -c '^--$' "${FAKE_GH_CALLS}"; }
want="$(expect "${T}/one.tar.gz" alice/CasaOS-foo v0.1.2; expect "${T}/two.tar.gz" alice/CasaOS-foo v0.1.2)"
[[ "${status}" == 0 && "$(cat "${FAKE_GH_CALLS}")" == "${want}" ]] && pass "two archives: the exact arguments, in order" || { fail "two archives: the exact arguments, in order"; cat "${FAKE_GH_CALLS}" "${T}/out"; }

FAKE_GH_FAIL_ON="${T}/two.tar.gz" run alice/CasaOS-foo v0.1.2 "${COMMIT}" "${T}/one.tar.gz" "${T}/two.tar.gz"
[[ "${status}" == 1 && "$(calls)" == 2 && "$(wc -l <"${T}/out")" == 1 ]] &&
    grep -q "alice/CasaOS-foo" "${T}/out" && grep -q "two.tar.gz" "${T}/out" && grep -q "not established" "${T}/out" && grep -q "no attestations found" "${T}/out" &&
    pass "a failure on the second: one sentence, exit 1, the first was verified" || { fail "a failure on the second"; cat "${T}/out"; }

FAKE_GH_FAIL_ON="${T}/one.tar.gz" run alice/CasaOS-foo v0.1.2 "${COMMIT}" "${T}/one.tar.gz" "${T}/two.tar.gz"
[[ "${status}" == 1 && "$(calls)" == 1 ]] && pass "a failure on the first stops there" || fail "a failure on the first stops there"

mkdir -p "${T}/sp ace"
echo three >"${T}/sp ace/th ree.tar.gz"
run alice/CasaOS-foo v0.1.2 "${COMMIT}" "${T}/sp ace/th ree.tar.gz"
[[ "${status}" == 0 && "$(cat "${FAKE_GH_CALLS}")" == "$(expect "${T}/sp ace/th ree.tar.gz" alice/CasaOS-foo v0.1.2)" ]] && pass "an archive path with a space stays one argument" || { fail "an archive path with a space stays one argument"; cat "${FAKE_GH_CALLS}"; }

nl=$'x
::error::x'
run "alice/${nl}" v0.1.2 "${COMMIT}" "${T}/one.tar.gz"
[[ "${status}" == 1 && "$(wc -l <"${T}/out")" == 1 && -z "$(grep '^::' "${T}/out")" && ! -s "${FAKE_GH_CALLS}" ]] && pass "a refused repository with a newline stays on one line" || { fail "a newline in a refused repository"; cat "${T}/out"; }
run alice/foo v0.1.2 "${COMMIT}" "${T}/${nl}.tar.gz"
[[ "${status}" == 1 && "$(wc -l <"${T}/out")" == 1 && -z "$(grep '^::' "${T}/out")" ]] && pass "an archive path with a newline stays on one line" || { fail "a newline in an archive path"; cat "${T}/out"; }
FAKE_GH_FAIL_ON="${T}/sp ace/th ree.tar.gz" run alice/CasaOS-foo v0.1.2 "${COMMIT}" "${T}/sp ace/th ree.tar.gz"
[[ "${status}" == 1 && "$(wc -l <"${T}/out")" == 1 ]] && pass "a failure names a path with a space on one line" || fail "a failure names a path with a space"

none() { # none LABEL ARGS...: refused with status 1 and no call
    local label="$1"
    shift
    run "$@"
    [[ "${status}" == 1 && ! -s "${FAKE_GH_CALLS}" && -s "${T}/out" ]] && pass "${label}" || { fail "${label}"; cat "${T}/out"; }
}
none "a commit of 39 digits" alice/CasaOS-foo v0.1.2 "${COMMIT:1}" "${T}/one.tar.gz"
none "a commit in upper case" alice/CasaOS-foo v0.1.2 "${COMMIT^^}" "${T}/one.tar.gz"
none "a repository with .." alice/CasaOS-.. v0.1.2 "${COMMIT}" "${T}/one.tar.gz"
none "a repository with a path" alice/../foo v0.1.2 "${COMMIT}" "${T}/one.tar.gz"
none "a repository of three parts" alice/foo/bar v0.1.2 "${COMMIT}" "${T}/one.tar.gz"
none "an owner ending with a hyphen" alice-/foo v0.1.2 "${COMMIT}" "${T}/one.tar.gz"
none "a tag without the v" alice/foo 0.1.2 "${COMMIT}" "${T}/one.tar.gz"
none "a tag with a branch in it" alice/foo v0.1.2/x "${COMMIT}" "${T}/one.tar.gz"
none "an archive that does not exist" alice/foo v0.1.2 "${COMMIT}" "${T}/one.tar.gz" "${T}/missing.tar.gz"
none "an archive that is a directory" alice/foo v0.1.2 "${COMMIT}" "${T}"
none "an archive that looks like an option" alice/foo v0.1.2 "${COMMIT}" --help

run alice/foo v0.1.2 "${COMMIT}"
[[ "${status}" == 2 && ! -s "${FAKE_GH_CALLS}" ]] && grep -q usage "${T}/out" && pass "no archive is usage" || fail "no archive is usage"

# a long error is cut to its first 300 printable characters
cat >"${T}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%0500d\001\n' 0 >&2
exit 1
EOF
run alice/foo v0.1.2 "${COMMIT}" "${T}/one.tar.gz"
[[ "${status}" == 1 && $(grep -cE ': 0{300} *$' "${T}/out") == 1 && "$(wc -l <"${T}/out")" == 1 ]] && pass "the error of gh is cut at 300 characters" || { fail "the error of gh is cut at 300 characters"; cat "${T}/out"; }

[[ "${failures}" == 0 ]]
