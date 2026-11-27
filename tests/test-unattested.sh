#!/usr/bin/env bash
# Offline tests of scripts/unattested.sh: the lookup and the check that the list only shrinks,
# also from a base that has no list. Needs bash and git.
#
#   bash tests/test-unattested.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

mkdir "${T}/repo" "${T}/repo/scripts"
cp "${ROOT}/scripts/unattested.sh" "${T}/repo/scripts/"
cd "${T}/repo" || exit 1
git init -q -b main
printf '# header\n\nvirt v0.2.7\nmcp v0.2.2\n' >unattested.txt
git add -A && git -c user.name=t -c user.email=t@invalid commit -qm base
U="bash scripts/unattested.sh"

$U has virt v0.2.7 && ! $U has virt v0.2.8 && ! $U has vir v0.2.7 && ! $U has virt v0.2 && pass "has: exact name and tag only" || fail "has: exact name and tag only"
$U check main >"${T}/out" 2>&1 && pass "check: unchanged file" || { fail "check: unchanged file"; cat "${T}/out"; }

printf '# header\nmcp v0.2.2\n' >unattested.txt
$U check main >"${T}/out" 2>&1 && pass "check: a line removed is fine (it shrinks)" || { fail "check: a line removed is fine"; cat "${T}/out"; }

printf '# header\nvirt v0.2.7\nmcp v0.2.2\nvirt v0.2.8\n' >unattested.txt
if ! $U check main >"${T}/out" 2>&1 && grep -q "virt v0.2.8" "${T}/out"; then pass "check: a new version is refused, named"; else fail "check: a new version is refused, named"; cat "${T}/out"; fi
$U check nope >/dev/null 2>&1; [[ $? == 2 ]] && pass "check: an unknown base ref is an error" || fail "check: an unknown base ref is an error"

printf 'virt v0.2.7\nnot a line\n' >unattested.txt
$U check main >/dev/null 2>&1; s=$?
$U has virt v0.2.7 >/dev/null 2>&1; h=$?
[[ "${s}" == 2 && "${h}" == 2 ]] && pass "a malformed line is an error (2), not an empty list" || fail "a malformed line is an error (2), not an empty list (${s} ${h})"

rm unattested.txt
$U has virt v0.2.7 >/dev/null 2>&1; [[ $? == 1 ]] && pass "no file: nothing is listed" || fail "no file: nothing is listed"

# a base that really has no unattested.txt: an empty list, but for the versions it was created with
mkdir "${T}/bare" "${T}/bare/scripts"
cp "${ROOT}/scripts/unattested.sh" "${T}/bare/scripts/"
cd "${T}/bare" || exit 1
git init -q -b main
git add -A && git -c user.name=t -c user.email=t@invalid commit -qm base
! git cat-file -e main:unattested.txt 2>/dev/null && pass "the bare base has no unattested.txt" || fail "the bare base has an unattested.txt"
printf '# header\nvirt v0.2.7\nvuln-scan v0.2.1\nmcp v0.2.2\n' >unattested.txt
$U check main >"${T}/out" 2>&1 && pass "check: base without the file, the change that creates it with its first versions passes" || { fail "check: base without the file, first versions"; cat "${T}/out"; }
printf 'mcp v0.2.2\n' >unattested.txt
$U check main >"${T}/out" 2>&1 && pass "check: base without the file, part of the first versions passes" || { fail "check: base without the file, part of the first versions"; cat "${T}/out"; }
printf 'virt v0.2.7\nvuln-scan v0.2.1\nmcp v0.2.2\nvirt v0.2.8\n' >unattested.txt
if ! $U check main >"${T}/out" 2>&1 && grep -q "virt v0.2.8" "${T}/out"; then pass "check: base without the file, any other version is refused, named"; else fail "check: base without the file, any other version is refused"; cat "${T}/out"; fi
printf 'wake-on-lan v0.1.0\n' >unattested.txt
$U check main >/dev/null 2>&1; [[ $? == 1 ]] && pass "check: base without the file, a list of other versions is refused" || fail "check: base without the file, a list of other versions is refused"

[[ "${failures}" == 0 ]] || { echo "${failures} failed"; exit 1; }
echo "all passed"
