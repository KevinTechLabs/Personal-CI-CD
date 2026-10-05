#!/usr/bin/env bash
# End-to-end smoke test against a running stack. Used by CI before any image
# is published, and handy by hand on AI-LAB:
#
#   scripts/smoke-test.sh http://localhost:8081 [expected-version]
#
# Checks readiness, the reported version, and that a task submitted to the
# API is picked up and completed by the worker through Postgres.

set -euo pipefail

BASE="${1:?usage: smoke-test.sh <base-url> [expected-version]}"
EXPECTED_VERSION="${2:-}"
TIMEOUT="${SMOKE_TIMEOUT:-60}"

fail() { echo "smoke: FAIL: $*" >&2; exit 1; }
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

echo "smoke: waiting for $BASE/ready"
for ((i = 0; i < TIMEOUT; i++)); do
  curl -fsS "$BASE/ready" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/ready" >/dev/null || fail "/ready never succeeded"

if [[ -n "$EXPECTED_VERSION" ]]; then
  version="$(curl -fsS "$BASE/version" | json '["version"]')"
  [[ "$version" == "$EXPECTED_VERSION" ]] || fail "version is '$version', expected '$EXPECTED_VERSION'"
  echo "smoke: version $version"
fi

task_id="$(curl -fsS -X POST "$BASE/api/tasks" \
  -H 'content-type: application/json' \
  -d '{"payload": "smoke test from the pipeline"}' | json '["id"]')"
echo "smoke: created task $task_id"

for ((i = 0; i < TIMEOUT; i++)); do
  status="$(curl -fsS "$BASE/api/tasks/$task_id" | json '["status"]')"
  case "$status" in
    done)   echo "smoke: task $task_id processed by worker"; break ;;
    failed) fail "task $task_id failed" ;;
  esac
  sleep 1
done
[[ "$status" == "done" ]] || fail "task $task_id still '$status' after ${TIMEOUT}s"

# Every dependency check should now be green, and the worker that just
# processed our task should be heartbeating with the expected version.
ready="$(curl -fsS "$BASE/ready")"
overall="$(json '["status"]' <<<"$ready")"
[[ "$overall" == "ready" ]] || fail "/ready is '$overall': $ready"
if [[ -n "$EXPECTED_VERSION" ]]; then
  json '["checks"]["worker"]["versions"]' <<<"$ready" | grep -q "$EXPECTED_VERSION" \
    || fail "no worker heartbeat from version $EXPECTED_VERSION: $ready"
fi
echo "smoke: all dependency checks ok"

curl -fsS "$BASE/metrics" | grep -q '^http_requests_total' || fail "/metrics missing request counter"
curl -fsS "$BASE/metrics" | grep -q '^readiness_check_state' || fail "/metrics missing readiness gauges"
echo "smoke: PASS"
