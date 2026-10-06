#!/usr/bin/env bash
# Scenario tests for deploy/agent/gitops-agent.sh.
#
# docker, cosign and curl are replaced by small stubs that simulate a host:
# the stubs track which release each environment is running, answer the
# health endpoints, and report an error ratio from "Prometheus". This lets
# CI exercise the agent's decisions (gating, rollback, drift healing)
# without a real homelab.
#
#   tests/agent/run.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
[[ -n "${KEEP_WORK:-}" ]] || trap 'rm -rf "$WORK"' EXIT

MOCK="$WORK/mock"; BIN="$WORK/bin"; mkdir -p "$MOCK" "$BIN"
export MOCK
PASS=0

# --------------------------------------------------------------------------- stubs
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
# Minimal docker stub: records calls, tracks the running release per project.
echo "docker $*" >> "$MOCK/calls.log"
[[ "$1" == network ]] && exit 0
[[ "$1" == info ]] && { echo "$MOCK"; exit 0; }   # DockerRootDir for the disk check
[[ "$1" == compose ]] || exit 0
shift
project="" release=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name) project="$2"; shift 2 ;;
    --env-file) [[ "$2" == */release.env ]] && release="$2"; shift 2 ;;
    --project-directory|--file) shift 2 ;;
    *) break ;;
  esac
done
version="$(sed -n 's/^APP_VERSION=//p' "$release")"
case "$1" in
  run)  [[ -f "$MOCK/fail-migrate-$version" ]] && exit 1; exit 0 ;;
  up)   echo "$version" > "$MOCK/$project.running"; rm -f "$MOCK/$project.down"; exit 0 ;;
  stop) rm -f "$MOCK/$project.running"; exit 0 ;;
  ps)   [[ -f "$MOCK/$project.down" ]] || printf 'api\ndb\nworker\n'; exit 0 ;;
  exec) # exec -T db <cmd...>: fake pg_dump / pg_restore --list
    shift; [[ "$1" == -T ]] && shift; shift
    case "$1" in
      pg_dump)
        [[ -f "$MOCK/fail-backup" ]] && exit 1
        if [[ -f "$MOCK/corrupt-backup" ]]; then echo "garbage"; else echo "PGDMP fake dump of $version"; fi ;;
      pg_restore)
        head -c5 | grep -q PGDMP && echo "1; 2615 2200 SCHEMA - public app" ;;
    esac
    exit 0 ;;
  *)    exit 0 ;;
esac
EOF

cat > "$BIN/cosign" <<'EOF'
#!/usr/bin/env bash
echo "cosign $*" >> "$MOCK/calls.log"
image="${!#}"
[[ -f "$MOCK/bad-signature" ]] && grep -qxF "$image" "$MOCK/bad-signature" && exit 1
exit 0
EOF

cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Answers /ready, /version and Prometheus queries from the stub state.
url=""; for a in "$@"; do [[ "$a" == http* ]] && url="$a"; done
if [[ "$url" == https://hc.test/* ]]; then   # off-box heartbeat
  [[ -f "$MOCK/heartbeat-down" ]] && exit 7
  echo "$url" >> "$MOCK/heartbeat.log"; exit 0
fi
if [[ "$url" == http://sentinel.test/* ]]; then   # record what the agent sends to Sentinel
  echo "$*" >> "$MOCK/sentinel-args.log"
  prev=""; for a in "$@"; do
    [[ "$prev" == -d ]] && echo "$a" >> "$MOCK/sentinel.jsonl"
    if [[ "$prev" == -H && "$a" == @* ]]; then cat "${a#@}" >> "$MOCK/sentinel-headers.log"; fi
    prev="$a"
  done
  exit 0
fi
case "$url" in
  *:8081/*) project=cicd-staging ;;
  *:8080/*) project=cicd-production ;;
esac
running="$(cat "$MOCK/$project.running" 2>/dev/null || true)"
case "$url" in
  */api/v1/query)
    query="${*: -1}"; env="${query#*env=\"}"; env="${env%%\"*}"
    running="$(cat "$MOCK/cicd-$env.running" 2>/dev/null || true)"
    ratio=0.0; [[ -f "$MOCK/errors-$running" ]] && ratio=0.5
    printf '{"status":"success","data":{"result":[{"value":[0,"%s"]}]}}' "$ratio" ;;
  */ready)
    [[ -n "$running" && ! -f "$MOCK/notready-$running" ]] || exit 22
    if [[ -f "$MOCK/legacy-$running" ]]; then   # release predating per-dependency /ready
      printf '{"status":"ready","schema":"0001"}'
    elif [[ -f "$MOCK/noworker-$running" ]]; then
      printf '{"status":"degraded","version":"%s","checks":{"worker":{"status":"degraded","versions":[]}}}' "$running"
    else
      printf '{"status":"ready","version":"%s","checks":{"worker":{"status":"ok","versions":["%s"]}}}' "$running" "$running"
    fi ;;
  */version)
    [[ -n "$running" ]] || exit 22
    printf '{"version":"%s"}' "$running" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN"/*

# --------------------------------------------------------------------------- git remote
REMOTE="$WORK/remote.git"
git init -q --bare "$REMOTE"
SRC="$WORK/src"
git clone -q "$REMOTE" "$SRC" 2>/dev/null
cp -r "$ROOT/deploy" "$ROOT/scripts" "$SRC/"
git -C "$SRC" add -A
git -C "$SRC" -c user.name=t -c user.email=t@t commit -qm init
git -C "$SRC" push -q origin HEAD:main 2>/dev/null

digest() { printf 'ghcr.io/test/app@sha256:%064d' "$1"; }
promote() { # promote <env> <version> [digest-seed]
  (cd "$SRC" && IMAGE_REF="$(digest "${3:-0}")" VERSION="$1" \
    scripts/promote.sh "$2" >/dev/null 2>&1) || return 1
}

# --------------------------------------------------------------------------- agent config
STATE="$WORK/state"; SECRETS="$WORK/secrets"; mkdir -p "$SECRETS"
for e in staging production; do echo "POSTGRES_PASSWORD=x" > "$SECRETS/$e.env"; done
cat > "$WORK/agent.env" <<EOF
REPO_URL=$REMOTE
STATE_DIR=$STATE
SECRETS_DIR=$SECRETS
READY_TIMEOUT=3
SOAK_SECONDS=1
SOAK_INTERVAL=0
COSIGN_IDENTITY_REGEXP=test
SENTINEL_URL=http://sentinel.test
BACKUP_KEEP=3
SENTINEL_KEY_FILE=$WORK/sentinel_key
HEARTBEAT_URL=https://hc.test/ping/abc
EOF
echo "s3cret-ingest-key-abcdef" > "$WORK/sentinel_key"

agent() {
  PATH="$BIN:$PATH" GITOPS_AGENT_CONFIG="$WORK/agent.env" \
    "$ROOT/deploy/agent/gitops-agent.sh" >> "$WORK/agent.log" 2>&1 || true
}
running() { cat "$MOCK/cicd-$1.running" 2>/dev/null || echo none; }
state()   { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$STATE/$1/status.json"; }

check() { # check <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "ok   - $1"
  else echo "FAIL - $1: got '$2', expected '$3'"; echo "--- agent log"; tail -30 "$WORK/agent.log"; exit 1; fi
}

metric() { # metric <name{labels}>: value from the agent's textfile metrics
  awk -v k="$1" '$1 == k {print $2}' "$STATE/metrics/gitops.prom"
}

# --------------------------------------------------------------------------- scenarios
agent
check "no environments branch yet: nothing deployed" "$(running staging)" none

promote aaaaaaa1 staging 1
agent
check "first staging deploy" "$(running staging)" aaaaaaa1
check "staging status is deployed" "$(state staging)" deployed

promote aaaaaaa1 production
agent
check "production deploys a staging-verified digest" "$(running production)" aaaaaaa1

touch "$MOCK/errors-bbbbbbb2"
promote bbbbbbb2 staging 2
agent
check "SLO breach rolls staging back" "$(running staging)" aaaaaaa1
check "staging status is rolled_back" "$(state staging)" rolled_back
calls_before="$(wc -l < "$MOCK/calls.log")"
agent
check "known-bad revision is not retried" "$(wc -l < "$MOCK/calls.log" | awk -v b="$calls_before" '{print ($1 - b < 10) ? "skipped" : "retried"}')" skipped

promote bbbbbbb2 production || true
agent
check "production refuses digest that failed staging" "$(running production)" aaaaaaa1
check "production status is waiting" "$(state production)" waiting

touch "$MOCK/fail-migrate-ccccccc3"
promote ccccccc3 staging 3
agent
check "failed migration leaves previous release serving" "$(running staging)" aaaaaaa1
check "staging status is failed" "$(state staging)" failed

touch "$MOCK/notready-ddddddd4"
promote ddddddd4 staging 4
agent
check "unready release rolls back" "$(running staging)" aaaaaaa1

printf 'ghcr.io/test/app@sha256:%064d\n' 5 > "$MOCK/bad-signature"
promote eeeeeee5 staging 5
agent
check "unsigned image is refused" "$(running staging)" aaaaaaa1
check "refused status is failed" "$(state staging)" failed

promote fffffff6 staging 6
agent
check "good release after failures deploys" "$(running staging)" fffffff6
agent
check "production keeps waiting on the unverified promotion" "$(state production)" waiting
promote fffffff6 production
agent
check "production follows verified staging release" "$(running production)" fffffff6

touch "$MOCK/cicd-staging.down"
agent
check "drift is healed" "$([[ -f "$MOCK/cicd-staging.down" ]] && echo down || echo up)" up

# --- worker-aware rollout ---------------------------------------------------
touch "$MOCK/noworker-a7a7a7a7"
promote a7a7a7a7 staging 7
agent
check "release whose worker never heartbeats is rolled back" "$(running staging)" fffffff6
check "rollback reason names the missing worker" \
  "$(grep -c 'no heartbeat from a a7a7a7a7 worker' "$WORK/agent.log" || true)" 1

# --- rollback to a release with the legacy /ready format ---------------------
touch "$MOCK/legacy-fffffff6"
touch "$MOCK/errors-b8b8b8b8"
promote b8b8b8b8 staging 8
agent
check "rollback to a legacy-/ready release succeeds" "$(state staging)" rolled_back
check "legacy release is serving again" "$(running staging)" fffffff6

# --- disk preflight ----------------------------------------------------------
promote c9c9c9c9 staging 9
MIN_FREE_DISK_MB=999999999 agent
check "low disk blocks the deploy" "$(running staging)" fffffff6
check "low disk status says it will retry" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["detail"])' "$STATE/staging/status.json")" "low disk space (will retry)"
agent
check "deploy proceeds once disk is available (not marked bad)" "$(running staging)" c9c9c9c9

# --- image pruning -------------------------------------------------------------
check "successful deploy prunes only this app's old images" \
  "$(grep -c 'docker image prune --all --force --filter until=168h --filter label=org.opencontainers.image.title=personal-ci-cd' "$MOCK/calls.log" || true)" 5

# --- agent metrics (node-exporter textfile) -----------------------------------
check "metrics: last run succeeded" "$(metric gitops_agent_last_run_success)" 1
check "metrics: staging deployed state" "$(metric 'gitops_environment_state{env="staging",state="deployed"}')" 1
check "metrics: staging rollbacks counted" "$(metric 'gitops_rollbacks_total{env="staging"}')" 4.0
check "metrics: staging deploys counted" "$(metric 'gitops_deploys_total{env="staging"}')" 3.0
check "metrics: drift heal counted" "$(metric 'gitops_drift_heals_total{env="staging"}')" 1.0
check "metrics: production version exported" "$(grep -c 'gitops_environment_info{env="production",version="fffffff6"' "$STATE/metrics/gitops.prom")" 1
check "metrics file is world-readable for node-exporter" "$(stat -c %a "$STATE/metrics/gitops.prom")" 644

# --- events sent to Sentinel ---------------------------------------------------
sentinel() { # sentinel <python expr over list E of events>
  python3 -c 'import json,sys; E=[json.loads(l) for l in open(sys.argv[1])]; print(eval(sys.argv[2]))' \
    "$MOCK/sentinel.jsonl" "$1"
}
check "Sentinel: each deploy reported as info" \
  "$(sentinel 'sum(1 for e in E if e["level"]=="info" and " deployed " in e["title"])')" 5
check "Sentinel: each rollback raised as high alert" \
  "$(sentinel 'sorted(e.get("key","").split(":")[1] for e in E if e["level"]=="high" and e.get("key","").startswith("rollback:"))')" \
  "['staging', 'staging', 'staging', 'staging']"
check "Sentinel: unsigned image raised as critical supply-chain alert" \
  "$(sentinel '[(e["level"], e["technique"], e["tactic"]) for e in E if e.get("key","").startswith("refused:")]')" \
  "[('critical', 'T1195.002', 'Initial Access')]"
check "Sentinel: failed migration reported" "$(sentinel 'sum(1 for e in E if e.get("key","").startswith("migration:"))')" 1
check "Sentinel: low disk reported" "$(sentinel 'sum(1 for e in E if e.get("key","").startswith("disk:"))')" 1
check "Sentinel: every event tagged with source and kind" \
  "$(sentinel 'all(e["source"]=="ai-lab" and e["kind"]=="GitOps" for e in E)')" True
check "Sentinel key sent as a header" \
  "$(grep -c 'Authorization: Bearer s3cret-ingest-key-abcdef' "$MOCK/sentinel-headers.log")" \
  "$(wc -l < "$MOCK/sentinel.jsonl")"
check "Sentinel key never on the command line" "$(grep -c 's3cret' "$MOCK/sentinel-args.log" || true)" 0

# --- database backups -----------------------------------------------------------
backups() { find "$STATE/backups/$1" -name '*.dump' -printf '%f\n' 2>/dev/null | sort; }
check "staging is not backed up by default" "$(backups staging | wc -l)" 0
check "first production deploy got a daily backup" "$(backups production | grep -c -- '-daily-' || true)" 1
check "production deploy over a live DB took a pre-migration backup" \
  "$(backups production | grep -c -- '-pre-fffffff6-' || true)" 1
check "backup files are private" "$(find "$STATE/backups/production" -name '*.dump' -perm 600 | wc -l)" "$(backups production | wc -l)"

promote d0d0d0d0 staging 10
agent
touch "$MOCK/fail-backup"
promote d0d0d0d0 production
agent
check "failed backup blocks the production migration" "$(running production)" fffffff6
check "blocked deploy status says it will retry" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["detail"])' "$STATE/production/status.json")" \
  "pre-migration backup failed (will retry)"
check "Sentinel told about the blocked deploy" \
  "$(sentinel 'sum(1 for e in E if e.get("key","")=="backup:production:d0d0d0d0")')" 1
rm -f "$MOCK/fail-backup"; touch "$MOCK/corrupt-backup"
agent
check "unverifiable backup also blocks it" "$(running production)" fffffff6
check "no corrupt dump left behind" "$(find "$STATE/backups/production" -name '*.partial' | wc -l)" 0
rm -f "$MOCK/corrupt-backup"
agent
check "deploy proceeds once a verified backup succeeds" "$(running production)" d0d0d0d0
check "retention keeps at most BACKUP_KEEP dumps" "$(( $(backups production | wc -l) <= 3 ))" 1
check "metrics: backup failures counted" "$(metric 'gitops_backup_failures_total{env="production"}')" 2.0
check "metrics: last backup timestamp exported" \
  "$(python3 -c 'import sys,time; print(abs(time.time()-float(sys.argv[1])) < 600)' "$(metric 'gitops_backup_last_timestamp_seconds{env="production"}')")" True

# --- DORA ---------------------------------------------------------------------
check "DORA: two staging incidents recovered" "$(metric 'gitops_recovery_seconds_count{env="staging"}')" 2.0
check "DORA: no production incidents" "$(metric 'gitops_recovery_seconds_count{env="production"}')" 0.0
check "DORA: no incident left open" "$(metric 'gitops_incident_open_since_timestamp_seconds{env="staging"}')" 0.0
# A release built from a real commit records lead time (commit -> running).
hour_ago="@$(( $(date +%s) - 3600 ))"
GIT_COMMITTER_DATE="$hour_ago" git -C "$SRC" -c user.name=t -c user.email=t@t \
  commit -q --allow-empty -m "feature" --date="$hour_ago"
real="$(git -C "$SRC" rev-parse HEAD)"
promote "$real" staging 11
check "release.env carries the commit time" "$(git --git-dir="$REMOTE" show environments:staging/release.env | grep -c '^COMMIT_TIMESTAMP=[1-9]')" 1
agent
check "DORA: lead time recorded for the real commit" "$(metric 'gitops_lead_time_seconds_count{env="staging"}')" 1.0
check "DORA: lead time is commit-to-running (~1h)" \
  "$(python3 -c 'import sys; print(3590 <= float(sys.argv[1]) < 3700)' "$(metric 'gitops_lead_time_seconds_sum{env="staging"}')")" True

# --- off-box heartbeat ----------------------------------------------------------
beats() { wc -l < "$MOCK/heartbeat.log" 2>/dev/null || echo 0; }
before="$(beats)"
agent
check "heartbeat sent after a quiet run" "$(( $(beats) - before ))" 1
before="$(beats)"
touch "$MOCK/notready-bbbbeee1"; promote bbbbeee1 staging 12
agent
check "heartbeat still sent when a deploy fails (liveness, not health)" "$(( $(beats) - before ))" 1
check "...and the failed deploy was rolled back" "$(running staging)" "$real"
touch "$MOCK/heartbeat-down"
hb_rc=0
PATH="$BIN:$PATH" GITOPS_AGENT_CONFIG="$WORK/agent.env" "$ROOT/deploy/agent/gitops-agent.sh" >> "$WORK/agent.log" 2>&1 || hb_rc=$?
check "unreachable heartbeat service doesn't fail the run" "$hb_rc" 0
rm -f "$MOCK/heartbeat-down"
exec 8>"$STATE/lock"; flock -n 8
before="$(beats)"
agent
check "no heartbeat while another run holds the lock (a hung agent goes silent)" "$(( $(beats) - before ))" 0
exec 8>&-

echo "all $PASS agent scenario checks passed"
