#!/usr/bin/env bash
# Offline tests of scripts/published.sh. No network: CURL is a fake curl that
# answers the HTTP status asked for, and GH a fake gh that answers the list of
# releases asked for. Needs bash and python3.
#
#   bash tests/test-published.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# FAKE_CURL_CODE: the status answered, its body written to -o (a 404 writes an HTML page, as GitHub does);
# FAKE_CURL_FAIL=1: writes part of a file, then fails as curl does on a cut connection
cat >"${T}/curl" <<'EOF'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
out = a[a.index("-o") + 1]
assert a[a.index("-w") + 1] == "%{http_code}" and a[-1].endswith("/releases/latest/download/catalogue-2.json"), a
code = os.environ.get("FAKE_CURL_CODE", "200")
open(out, "w").write('{"schema": 2}' if code == "200" else "<!DOCTYPE html><html>Not Found</html>")
if os.environ.get("FAKE_CURL_FAIL"):
    sys.exit(56)
print(code, end="")
EOF
# FAKE_GH_OUT: what `gh api` prints; FAKE_GH_FAIL=1: it fails
cat >"${T}/gh" <<'EOF'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
open(os.environ["FAKE_GH_CALLS"], "a").write(" ".join(a) + "\n")
assert a == ["api", "repos/ReCasaOS/modules/releases?per_page=1"], a
if os.environ.get("FAKE_GH_FAIL"):
    sys.exit("fake gh: HTTP 502")
print(os.environ.get("FAKE_GH_OUT", "[]"))
EOF
chmod +x "${T}/curl" "${T}/gh"

out="${T}/published.json"
run() { # run [VAR=value...]: published.sh OUT, output in ${T}/log, gh calls in ${T}/calls; OUT starts stale
    echo stale >"${out}"
    : >"${T}/calls"
    env CURL="${T}/curl" GH="${T}/gh" FAKE_GH_CALLS="${T}/calls" GITHUB_REPOSITORY=ReCasaOS/modules "$@" \
        bash "${ROOT}/scripts/published.sh" "${out}" >"${T}/log" 2>&1
}
one_line() { [[ "$(grep -c . "${T}/log")" == 1 ]]; }

# 1. 200: the file is at OUT, and no release list is needed
if run FAKE_CURL_CODE=200 && [[ "$(cat "${out}")" == '{"schema": 2}' ]] && [[ ! -s "${T}/calls" ]]; then
    pass "200 writes the published file to OUT"
else
    fail "200 writes the published file to OUT"; cat "${T}/log"
fi

# 2. 404 and no release at all: nothing published yet, exit 0, no file
if run FAKE_CURL_CODE=404 FAKE_GH_OUT='[]' && [[ ! -e "${out}" ]] && grep -q "nothing is published yet" "${T}/log"; then
    pass "404 with no release: nothing published yet, exit 0, no file"
else
    fail "404 with no release: nothing published yet, exit 0, no file"; cat "${T}/log"
fi

# 3. 404 while a release exists: refused, one sentence, no file
if ! run FAKE_CURL_CODE=404 FAKE_GH_OUT='[{"tag_name": "c5", "draft": false}]' && [[ ! -e "${out}" ]] &&
    one_line && grep -q "has a release" "${T}/log"; then
    pass "404 while a release exists: refused in one sentence, no file"
else
    fail "404 while a release exists: refused in one sentence, no file"; cat "${T}/log"
fi

# 4. another status, or a cut download: refused, no file
for code in 500 403 301; do
    if ! run FAKE_CURL_CODE="${code}" && [[ ! -e "${out}" ]] && one_line && grep -q "HTTP ${code}" "${T}/log"; then
        pass "HTTP ${code}: refused, no file"
    else
        fail "HTTP ${code}: refused, no file"; cat "${T}/log"
    fi
done
if ! run FAKE_CURL_FAIL=1 && [[ ! -e "${out}" ]] && one_line; then
    pass "a curl failure: refused, no file"
else
    fail "a curl failure: refused, no file"; cat "${T}/log"
fi

# 5. the releases cannot be listed, or the answer is not a list: never read as "none"
if ! run FAKE_CURL_CODE=404 FAKE_GH_FAIL=1 && [[ ! -e "${out}" ]] && grep -q "could not be listed" "${T}/log"; then
    pass "gh failing on a 404: refused, no file"
else
    fail "gh failing on a 404: refused, no file"; cat "${T}/log"
fi
for answer in '{"message": "Not Found"}' '' 'null' '<html>'; do
    if ! run FAKE_CURL_CODE=404 FAKE_GH_OUT="${answer}" && [[ ! -e "${out}" ]] && one_line; then
        pass "gh answering '${answer}' on a 404: refused, no file"
    else
        fail "gh answering '${answer}' on a 404: refused, no file"; cat "${T}/log"
    fi
done

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL: ${failures} test(s)"
    exit 1
fi
