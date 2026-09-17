#!/usr/bin/env bash
#
# Functional smoke test against the deployed application.
# Exits non-zero if any assertion fails, so it can gate a pipeline.
set -uo pipefail   # deliberately NOT -e: we want every test to run and
                   # report, rather than aborting on the first failure.

BASE="${BASE_URL:-http://lab.localhost}"
PASS=0
FAIL=0

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    green "  PASS  $name"
    PASS=$((PASS + 1))
  else
    red   "  FAIL  $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "Testing $BASE"
echo

# ---------------------------------------------------------------------------
echo "Health"
check "liveness returns 200"  "200" "$(status "$BASE/healthz")"
check "readiness returns 200" "200" "$(status "$BASE/readyz")"

# ---------------------------------------------------------------------------
echo
echo "Counter"
# A unique key per run keeps the test independent of previous runs --
# otherwise the second run starts from a non-zero value and the assertion
# below is wrong. Test isolation matters as much here as in unit tests.
KEY="smoke-$(date +%s)-$RANDOM"

before="$(curl -s "$BASE/counter/$KEY" | jq -r .value)"
check "new counter starts at 0" "0" "$before"

curl -s -X POST "$BASE/counter/$KEY" >/dev/null
curl -s -X POST "$BASE/counter/$KEY" >/dev/null
curl -s -X POST "$BASE/counter/$KEY" >/dev/null

after="$(curl -s "$BASE/counter/$KEY" | jq -r .value)"
check "three increments yield 3" "3" "$after"

# ---------------------------------------------------------------------------
echo
echo "Key/value"
curl -s -X PUT "$BASE/kv/$KEY" \
  -H 'Content-Type: application/json' \
  -d '{"value":"hello"}' >/dev/null

check "stored value reads back" "hello" "$(curl -s "$BASE/kv/$KEY" | jq -r .value)"
check "missing key returns 404" "404" "$(status "$BASE/kv/definitely-not-here-$RANDOM")"
check "delete returns 200"      "200" "$(status -X DELETE "$BASE/kv/$KEY")"
check "deleted key returns 404" "404" "$(status "$BASE/kv/$KEY")"

# ---------------------------------------------------------------------------
echo
echo "Load balancing"
# Twelve requests across three replicas should touch more than one pod.
# This asserts the Service is actually distributing traffic rather than
# pinning to a single endpoint.
instances="$(for _ in $(seq 1 12); do
  curl -s "$BASE/" | jq -r .instance
done | sort -u | wc -l)"

if (( instances > 1 )); then
  green "  PASS  requests spread across $instances pods"
  PASS=$((PASS + 1))
else
  red   "  FAIL  all requests served by a single pod"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo
echo "-------------------------"
green "Passed: $PASS"
[[ $FAIL -gt 0 ]] && red "Failed: $FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))