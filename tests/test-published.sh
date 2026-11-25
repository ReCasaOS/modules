#!/usr/bin/env bash
# Offline tests of scripts/published.sh. No network: CURL is a fake curl that
# answers the HTTP status asked for, and GH a fake gh that answers the latest
# release and the list of releases asked for. Needs bash and python3.
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
# FAKE_CURL_CODE_FOR=FILE:CODE: another status for that file only;
# FAKE_CURL_FAIL=1: writes part of a file, then fails as curl does on a cut connection
cat >"${T}/curl" <<'EOF'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
out = a[a.index("-o") + 1]
url = a[-1]
assert a[a.index("-w") + 1] == "%{http_code}" and a[a.index("--max-filesize") + 1] == "1048576", a
assert url.startswith("https://github.com/ReCasaOS/modules/releases/download/c3/catalogue-"), a
file = url.rsplit("/", 1)[1]
code = os.environ.get("FAKE_CURL_CODE", "200")
for rule in os.environ.get("FAKE_CURL_CODE_FOR", "").split():
    if rule.split(":")[0] == file:
        code = rule.split(":")[1]
schema = 3 if file == "catalogue-3.json" else 2
serial = os.environ.get("FAKE_SERIAL_3", "7") if schema == 3 else "7"
body = '{"schema": %d, "serial": %s, "generated": "2026-11-25T12:00:00Z", %s"modules": []}' % (schema, serial, '"withdrawn": [], ' if schema == 3 else "")
open(os.environ["FAKE_GH_CALLS"] + ".curl", "a").write(url + "\n")
open(out, "w").write(body if code == "200" else "<!DOCTYPE html><html>Not Found</html>")
if os.environ.get("FAKE_CURL_FAIL"):
    sys.exit(56)
print(code, end="")
EOF
# FAKE_GH_LATEST: the latest release as JSON; FAKE_GH_LATEST_ERR: it fails, saying that on the standard error;
# FAKE_GH_OUT: what the list of releases prints; FAKE_GH_FAIL=1: the list fails
cat >"${T}/gh" <<'EOF'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
open(os.environ["FAKE_GH_CALLS"], "a").write(" ".join(a) + "\n")
if a == ["api", "repos/ReCasaOS/modules/releases/latest"]:
    if os.environ.get("FAKE_GH_LATEST_ERR"):
        sys.exit(os.environ["FAKE_GH_LATEST_ERR"])
    print(os.environ["FAKE_GH_LATEST"])
    sys.exit(0)
assert a == ["api", "repos/ReCasaOS/modules/releases?per_page=1"], a
if os.environ.get("FAKE_GH_FAIL"):
    sys.exit("fake gh: HTTP 502")
print(os.environ.get("FAKE_GH_OUT", "[]"))
EOF
chmod +x "${T}/curl" "${T}/gh"

dir="${T}/published"
release() { # release FILE...: the latest release, with these catalogue files and another file among its assets
    python3 -c 'import json, sys; print(json.dumps({"tag_name": "c3", "assets": [{"name": n} for n in ["other.txt"] + sys.argv[1:]]}))' "$@"
}
both="$(release catalogue-2.json catalogue-3.json)"
only2="$(release catalogue-2.json)"
run() { # run [VAR=value...]: published.sh DIR, output in ${T}/log, gh calls in ${T}/calls; DIR starts with stale files
    mkdir -p "${dir}"
    echo stale >"${dir}/catalogue-2.json"
    echo stale >"${dir}/catalogue-3.json"
    : >"${T}/calls"
    : >"${T}/calls.curl"
    env CURL="${T}/curl" GH="${T}/gh" FAKE_GH_CALLS="${T}/calls" GITHUB_REPOSITORY=ReCasaOS/modules "$@" \
        bash "${ROOT}/scripts/published.sh" "${dir}" >"${T}/log" 2>&1
}
one_line() { [[ "$(grep -c . "${T}/log")" == 1 ]]; }
files() { (cd "${dir}" && ls | tr '\n' ' '); }
empty() { [[ -d "${dir}" && -z "$(ls -A "${dir}")" ]]; }

# 1. a release with both files: both are written, read from the addresses the boxes read
if run FAKE_GH_LATEST="${both}" && [[ "$(files)" == "catalogue-2.json catalogue-3.json " ]] &&
    grep -q '"schema": 2' "${dir}/catalogue-2.json" && grep -q '"schema": 3' "${dir}/catalogue-3.json" && grep -q "releases/download/c3/catalogue-3.json" "${T}/calls.curl"; then
    pass "a release with both files writes both"
else
    fail "a release with both files writes both"; cat "${T}/log"
fi

# 2. a release without catalogue-3.json (c3, before schema 3): exit 0, one file; the list says so, no 404 is needed
if run FAKE_GH_LATEST="${only2}" && [[ "$(files)" == "catalogue-2.json " ]] && grep -q '"schema": 2' "${dir}/catalogue-2.json"; then
    pass "a release without catalogue-3.json writes catalogue-2.json only, exit 0"
else
    fail "a release without catalogue-3.json writes catalogue-2.json only, exit 0"; cat "${T}/log"
fi

# 3. a file listed that does not download: refused, no file left
if ! run FAKE_GH_LATEST="${both}" FAKE_CURL_CODE_FOR=catalogue-3.json:404 && empty && one_line && grep -q "catalogue-3.json answered HTTP 404" "${T}/log"; then
    pass "a listed file that answers 404: refused in one sentence, no file"
else
    fail "a listed file that answers 404: refused in one sentence, no file"; cat "${T}/log"; files
fi
if ! run FAKE_GH_LATEST="${both}" FAKE_CURL_CODE_FOR=catalogue-2.json:500 && empty && one_line && grep -q "HTTP 500" "${T}/log"; then
    pass "a listed file that answers 500: refused, no file"
else
    fail "a listed file that answers 500: refused, no file"; cat "${T}/log"; files
fi
if ! run FAKE_GH_LATEST="${both}" FAKE_CURL_FAIL=1 && empty && one_line; then
    pass "a curl failure: refused, no file"
else
    fail "a curl failure: refused, no file"; cat "${T}/log"; files
fi

# 3b. one release is read as a whole: two files of two publications, a tag that is no c<serial>, a repository that is none
if ! run FAKE_GH_LATEST="${both}" FAKE_SERIAL_3=8 && empty && one_line && grep -q "same serial" "${T}/log"; then
    pass "two files of another serial: refused, no file"
else
    fail "two files of another serial: refused, no file"; cat "${T}/log"; files
fi
for tag in 'x' 'c0' 'c03' 'c3/../x' ''; do
    if ! run FAKE_GH_LATEST="$(python3 -c 'import json, sys; print(json.dumps({"tag_name": sys.argv[1], "assets": [{"name": "catalogue-2.json"}]}))' "${tag}")" && empty && one_line && [[ ! -s "${T}/calls.curl" ]]; then
        pass "the tag '${tag}': refused before any download"
    else
        fail "the tag '${tag}': refused before any download"; cat "${T}/log"; files
    fi
done
for badrepo in '' 'ReCasaOS' 'a/b/c' 'ReCasaOS/modules;x' '../x' 'a/..' 'a/.' './x'; do
    if ! run GITHUB_REPOSITORY="${badrepo}" FAKE_GH_LATEST="${both}" && one_line && empty && [[ ! -s "${T}/calls" ]]; then
        pass "the repository '${badrepo}': refused before any call"
    else
        fail "the repository '${badrepo}': refused before any call"; cat "${T}/log"
    fi
done

# 4. no release at all: exit 0, the folder exists and is empty
if run FAKE_GH_LATEST_ERR='gh: Not Found (HTTP 404)' FAKE_GH_OUT='[]' && empty && grep -q "nothing is published yet" "${T}/log"; then
    pass "no release: nothing published yet, exit 0, an empty folder"
else
    fail "no release: nothing published yet, exit 0, an empty folder"; cat "${T}/log"; files
fi
if env CURL="${T}/curl" GH="${T}/gh" FAKE_GH_CALLS="${T}/calls" GITHUB_REPOSITORY=ReCasaOS/modules FAKE_GH_LATEST_ERR='HTTP 404' \
    bash "${ROOT}/scripts/published.sh" "${T}/new/sub" >"${T}/log" 2>&1 && [[ -d "${T}/new/sub" && -z "$(ls -A "${T}/new/sub")" ]]; then
    pass "the folder is created when it does not exist"
else
    fail "the folder is created when it does not exist"; cat "${T}/log"
fi

# 5. a 404 on the latest release while a release exists: refused
if ! run FAKE_GH_LATEST_ERR='gh: Not Found (HTTP 404)' FAKE_GH_OUT='[{"tag_name": "c5", "draft": false}]' && empty && one_line && grep -q "has a release" "${T}/log"; then
    pass "404 while a release exists: refused in one sentence, no file"
else
    fail "404 while a release exists: refused in one sentence, no file"; cat "${T}/log"; files
fi

# 6. the latest release has no catalogue-2.json, or does not list files: refused, never nothing published
for latest in "$(release catalogue-3.json)" "$(release)" '{"tag_name": "c1"}' '[]' ''; do
    if ! run FAKE_GH_LATEST="${latest}" && empty && one_line; then
        pass "a latest release of '${latest:0:40}': refused, no file"
    else
        fail "a latest release of '${latest:0:40}': refused, no file"; cat "${T}/log"; files
    fi
done

# 6b. gh saying 404 in other words is not a 404 of the API
if ! run FAKE_GH_LATEST_ERR='error 404 somewhere' FAKE_GH_OUT='[]' && empty && one_line && [[ "$(grep -c 'per_page' "${T}/calls")" == 0 ]]; then
    pass "a failure that does not say HTTP 404: refused, never nothing published"
else
    fail "a failure that does not say HTTP 404: refused, never nothing published"; cat "${T}/log"; files
fi

# 7. another failure of the latest release: refused, it is not a 404
if ! run FAKE_GH_LATEST_ERR='fake gh: HTTP 502' && empty && one_line && [[ "$(grep -c 'per_page' "${T}/calls")" == 0 ]]; then
    pass "HTTP 502 on the latest release: refused, never read as nothing published"
else
    fail "HTTP 502 on the latest release: refused, never read as nothing published"; cat "${T}/log"; files
fi

# 8. the releases cannot be listed, or the answer is not a list: never read as "none"
if ! run FAKE_GH_LATEST_ERR='HTTP 404' FAKE_GH_FAIL=1 && empty && grep -q "could not be listed" "${T}/log"; then
    pass "gh failing on a 404: refused, no file"
else
    fail "gh failing on a 404: refused, no file"; cat "${T}/log"; files
fi
for answer in '{"message": "Not Found"}' '' 'null' '<html>'; do
    if ! run FAKE_GH_LATEST_ERR='HTTP 404' FAKE_GH_OUT="${answer}" && empty && one_line; then
        pass "gh answering '${answer}' on a 404: refused, no file"
    else
        fail "gh answering '${answer}' on a 404: refused, no file"; cat "${T}/log"; files
    fi
done

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL: ${failures} test(s)"
    exit 1
fi
