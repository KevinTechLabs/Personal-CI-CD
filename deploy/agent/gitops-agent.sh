#!/usr/bin/env bash
# GitOps agent for AI-LAB.
#
# Pull-based deployment: every run fetches the `environments` branch and
# makes each environment's Docker Compose stack match what is committed
# there. Nothing in CI can reach this host; CI only commits to Git.
#
# For each environment whose desired state changed, the agent:
#   1. refuses production digests that have not first passed on staging here
#   2. verifies the image's Sigstore signature and SBOM attestation
#   3. pulls, then runs database migrations while the old release still serves
#   4. checks the host has enough free disk for the new images, and for
#      production takes a verified pg_dump before touching the schema
#   5. replaces the app containers and waits until /ready passes, the API
#      reports the new version, AND a worker running the new version is
#      heartbeating (so a crash-looping worker can't slip through)
#   6. soaks: sends synthetic traffic and watches readiness, the worker
#      heartbeat and the error-ratio SLO in Prometheus; on any failure it rolls
#      back to the last good release and remembers the bad revision
#
# It also self-heals drift (restarts the applied release if its containers
# stop), takes a daily database backup, prunes old release images, and exports its own metrics through the
# node-exporter textfile collector so Prometheus can alert if it stops running.
#
# Run by systemd (deploy/agent/gitops-agent.timer). Config: agent.env.

set -Eeuo pipefail
shopt -s inherit_errexit

CONFIG_FILE="${GITOPS_AGENT_CONFIG:-/etc/gitops-agent/agent.env}"
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

: "${REPO_URL:?REPO_URL must be set in $CONFIG_FILE}"
BRANCH="${BRANCH:-environments}"
ENVIRONMENTS="${ENVIRONMENTS:-staging production}"
STATE_DIR="${STATE_DIR:-/var/lib/gitops-agent}"
SECRETS_DIR="${SECRETS_DIR:-/etc/gitops-agent/secrets}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
SOAK_SECONDS="${SOAK_SECONDS:-150}"
SOAK_INTERVAL="${SOAK_INTERVAL:-15}"
MAX_ERROR_RATIO="${MAX_ERROR_RATIO:-0.05}"
REQUIRE_PROMETHEUS="${REQUIRE_PROMETHEUS:-false}"
VERIFY_SIGNATURES="${VERIFY_SIGNATURES:-true}"
REQUIRE_SBOM_ATTESTATION="${REQUIRE_SBOM_ATTESTATION:-true}"
COSIGN_ISSUER="${COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"
COSIGN_IDENTITY_REGEXP="${COSIGN_IDENTITY_REGEXP:-}"
SENTINEL_URL="${SENTINEL_URL:-}"
SENTINEL_KEY_FILE="${SENTINEL_KEY_FILE:-/etc/gitops-agent/sentinel_key}"
SENTINEL_SOURCE="${SENTINEL_SOURCE:-ai-lab}"
MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-2048}"
PRUNE_IMAGES="${PRUNE_IMAGES:-true}"
PRUNE_AFTER="${PRUNE_AFTER:-168h}"
METRICS_DIR="${METRICS_DIR:-$STATE_DIR/metrics}"
BACKUP_ENVIRONMENTS="${BACKUP_ENVIRONMENTS:-production}"
BACKUP_DIR="${BACKUP_DIR:-$STATE_DIR/backups}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"
BACKUP_EVERY_HOURS="${BACKUP_EVERY_HOURS:-24}"
HEARTBEAT_URL="${HEARTBEAT_URL:-}"
DOWNTIME_ALERT_MINUTES="${DOWNTIME_ALERT_MINUTES:-5}"
PROC_STAT="${PROC_STAT:-/proc/stat}"

REPO_DIR="$STATE_DIR/repo"
VERIFIED_DIGESTS="$STATE_DIR/verified-digests"

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${CURRENT_ENV:-agent}" "$*"; }
warn() { log "WARN: $*" >&2; }

notify() {
  # notify <level> <title> <text> [dedupe-key] [ATT&CK technique] [tactic]
  # Sends a deploy event to Sentinel (Homelab-Soc-Dashboard). level "info" only
  # goes to its activity feed; low..critical raise an alert there (high and
  # critical also reach Discord). Optional: without SENTINEL_URL it's a no-op.
  local level="$1" title="$2" text="$3" key="${4:-}" tech="${5:-}" tac="${6:-}" payload
  NOTIFY_FAILED=0
  [[ -n "$SENTINEL_URL" && -r "$SENTINEL_KEY_FILE" ]] || return 0
  payload="$(python3 -c 'import json, sys
k = ["source", "kind", "level", "title", "text", "key", "technique", "tactic"]
print(json.dumps({a: b for a, b in zip(k, sys.argv[1:]) if b}))' \
    "$SENTINEL_SOURCE" GitOps "$level" "$title" "$text" "$key" "$tech" "$tac")"
  # Header from a file descriptor so the key never appears in the process list.
  curl -fsS -m 10 -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$SENTINEL_KEY_FILE")") \
    -H 'Content-Type: application/json' -d "$payload" \
    "$SENTINEL_URL/api/ingest/event" >/dev/null && return 0
  warn "could not reach Sentinel"
  NOTIFY_FAILED=1
}

heartbeat() {
  # Off-box dead man's switch: tells an external monitor (e.g. healthchecks.io)
  # "this host and its agent are alive". Sentinel runs on this same machine,
  # so it can't report the machine itself going down; the external monitor
  # alerts you when these pings stop. Sent at the end of every run (deploy
  # or not), so a crashed or hung agent also stops the pings. Optional.
  [[ -n "$HEARTBEAT_URL" ]] || return 0
  curl -fsS -m 10 --retry 2 -o /dev/null "$HEARTBEAT_URL" || warn "could not reach heartbeat URL"
}

check_downtime() {
  # Runs at the start of every agent run. The timer fires ~60s after the
  # previous run ends, so a gap much longer than that means this host (or
  # the agent) was down. Sentinel runs on this host too, so it couldn't be
  # told at the time; it's told now, after the fact. The report is kept
  # until Sentinel accepts it (Sentinel may still be starting after a boot).
  local alive="$STATE_DIR/last-alive" pending="$STATE_DIR/downtime-pending"
  local now last boot gap
  now="$(date +%s)"
  last="$(cat "$alive" 2>/dev/null || true)"
  echo "$now" > "$alive"
  if [[ "$last" =~ ^[0-9]+$ && ! -f "$pending" ]]; then
    gap=$((now - last))
    if ((gap > DOWNTIME_ALERT_MINUTES * 60)); then
      boot="$(awk '/^btime/ {print $2}' "$PROC_STAT" 2>/dev/null || true)"
      if [[ "$boot" =~ ^[0-9]+$ ]] && ((boot > last)); then
        printf 'reboot %s %s %s\n' "$last" "$now" "$boot" > "$pending"
      else
        printf 'stopped %s %s -\n' "$last" "$now" > "$pending"
      fi
    fi
  fi
  [[ -f "$pending" ]] || return 0

  local kind from to booted mins span
  read -r kind from to booted < "$pending"
  mins=$(( (to - from) / 60 ))
  span="$(date -d "@$from" '+%F %H:%M') → $(date -d "@$to" '+%H:%M %Z')"
  if [[ "$kind" == reboot ]]; then
    log "host was down for ${mins}m ($span), rebooted at $(date -d "@$booted" '+%H:%M')"
    notify high "$SENTINEL_SOURCE was offline for ${mins}m" \
      "No agent runs $span; the machine rebooted at $(date -d "@$booted" '+%H:%M') (power loss, crash or restart). Everything on it, Sentinel included, was down; containers have restarted. Check: journalctl --list-boots" \
      "downtime:$from" T1529 Impact
  else
    log "agent did not run for ${mins}m ($span); the host stayed up"
    notify medium "GitOps agent on $SENTINEL_SOURCE didn't run for ${mins}m" \
      "No agent runs $span, but the machine didn't reboot: the timer was stopped (paused deploys?) or the agent hung. Check: systemctl status gitops-agent.timer" \
      "downtime:$from" T1489 Impact
  fi
  ((NOTIFY_FAILED)) || rm -f "$pending"
}

bump() { # bump <file>: increment a persisted counter
  local n; n="$(cat "$1" 2>/dev/null || echo 0)"
  echo $((n + 1)) > "$1"
}

# Read one KEY=value from an env file without executing it.
env_value() { sed -n "s/^$2=//p" "$1" | tail -1; }

write_status() {
  local env="$1" state="$2" detail="$3" version="${4:-}"
  python3 - "$STATE_DIR/$env/status.json" "$env" "$state" "$detail" "$version" <<'PY'
import json, sys, datetime
path, env, state, detail, version = sys.argv[1:]
json.dump({"environment": env, "state": state, "detail": detail, "version": version,
           "at": datetime.datetime.now(datetime.UTC).isoformat()}, open(path, "w"), indent=2)
PY
}

compose() {
  # compose <env> <dir> <args...>: run docker compose against a release dir.
  local env="$1" dir="$2"; shift 2
  docker compose \
    --project-name "cicd-$env" \
    --project-directory "$dir" \
    --file "$dir/compose.yaml" \
    --env-file "$dir/config.env" \
    --env-file "$dir/release.env" \
    --env-file "$SECRETS_DIR/$env.env" \
    "$@"
}

# ---------------------------------------------------------------------------
sync_repo() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    if ! git ls-remote --exit-code --heads "$REPO_URL" "$BRANCH" >/dev/null 2>&1; then
      log "branch '$BRANCH' does not exist yet; nothing has been promoted"
      return 1
    fi
    git clone --quiet --single-branch --branch "$BRANCH" --depth 20 "$REPO_URL" "$REPO_DIR"
  else
    git -C "$REPO_DIR" fetch --quiet --depth 20 origin "$BRANCH"
    git -C "$REPO_DIR" reset --quiet --hard FETCH_HEAD
    git -C "$REPO_DIR" clean --quiet -fdx
  fi
}

verify_image() {
  local image="$1"
  [[ "$VERIFY_SIGNATURES" == "true" ]] || { warn "signature verification disabled"; return 0; }
  [[ -n "$COSIGN_IDENTITY_REGEXP" ]] || { warn "COSIGN_IDENTITY_REGEXP unset; refusing to deploy"; return 1; }
  cosign verify --output text \
    --certificate-oidc-issuer "$COSIGN_ISSUER" \
    --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
    "$image" >/dev/null || return 1
  if [[ "$REQUIRE_SBOM_ATTESTATION" == "true" ]]; then
    cosign verify-attestation --type spdxjson \
      --certificate-oidc-issuer "$COSIGN_ISSUER" \
      --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
      "$image" >/dev/null || return 1
  fi
  log "signature and SBOM attestation verified"
}

readiness() {
  # readiness <port> <version>: prints "ok" or the reason the release isn't
  # ready yet. Understands both /ready formats so rolling back to a release
  # that predates the per-dependency report still works.
  local port="$1" want="$2" body api_version
  body="$(curl -fsS -m 3 "http://127.0.0.1:$port/ready" 2>/dev/null)" || { echo "/ready not 200"; return; }
  api_version="$(curl -fsS -m 3 "http://127.0.0.1:$port/version" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
  python3 - "$body" "$want" "$api_version" <<'PY'
import json, sys
body, want, api_version = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
if api_version != want:
    print(f"API reports version {api_version or '?'}, want {want[:12]}")
elif "checks" not in body:
    print("ok")  # legacy /ready: HTTP 200 + version match is all it can say
else:
    worker = body["checks"].get("worker", {})
    if want not in worker.get("versions", []):
        live = ",".join(v[:12] for v in worker.get("versions", [])) or "none"
        print(f"no heartbeat from a {want[:12]} worker (live: {live})")
    else:
        print("ok")
PY
}

wait_ready() {
  local port="$1" want_version="$2" deadline=$((SECONDS + READY_TIMEOUT)) why=""
  while ((SECONDS < deadline)); do
    why="$(readiness "$port" "$want_version")"
    [[ "$why" == "ok" ]] && return 0
    sleep 2
  done
  warn "not ready: $why"
  return 1
}

error_ratio() {
  # Prints the env's current 5xx ratio, "none" if there is no traffic data,
  # or "unavailable" if Prometheus cannot be queried.
  local env="$1" body
  body="$(curl -fsS -m 5 --get "$PROMETHEUS_URL/api/v1/query" \
    --data-urlencode "query=env:http_error_ratio:rate2m{env=\"$env\"}" 2>/dev/null)" \
    || { echo unavailable; return; }
  python3 -c '
import json, math, sys
result = json.loads(sys.argv[1])["data"]["result"]
value = float(result[0]["value"][1]) if result else float("nan")
print("none" if math.isnan(value) else value)
' "$body" 2>/dev/null || echo unavailable
}

synthetic_traffic() {
  local port="$1"
  for _ in 1 2 3 4 5; do
    curl -s -o /dev/null -m 3 "http://127.0.0.1:$port/" || true
    curl -s -o /dev/null -m 3 "http://127.0.0.1:$port/api/tasks?limit=1" || true
  done
}

soak() {
  # Watch the new release; return non-zero on SLO breach, readiness loss or
  # the new worker's heartbeat disappearing.
  local env="$1" port="$2" version="$3" deadline=$((SECONDS + SOAK_SECONDS)) ratio why
  log "soaking for ${SOAK_SECONDS}s (max error ratio $MAX_ERROR_RATIO)"
  while ((SECONDS < deadline)); do
    synthetic_traffic "$port"
    why="$(readiness "$port" "$version")"
    if [[ "$why" != "ok" ]]; then
      warn "readiness lost during soak: $why"
      return 1
    fi
    ratio="$(error_ratio "$env")"
    case "$ratio" in
      unavailable)
        if [[ "$REQUIRE_PROMETHEUS" == "true" ]]; then
          warn "Prometheus unavailable and REQUIRE_PROMETHEUS=true"; return 1
        fi
        warn "Prometheus unavailable; relying on readiness only" ;;
      none) ;;
      *)
        log "error ratio: $ratio"
        if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)' \
            "$ratio" "$MAX_ERROR_RATIO"; then
          warn "SLO breached: error ratio $ratio > $MAX_ERROR_RATIO"
          return 1
        fi ;;
    esac
    sleep "$SOAK_INTERVAL"
  done
}

rollback() {
  local env="$1" reason="$2" rev="$3" version="$4"
  local applied="$STATE_DIR/$env/applied"
  warn "rolling back: $reason"
  echo "$rev" > "$STATE_DIR/$env/failed.rev"
  bump "$STATE_DIR/$env/rollbacks_total"
  # DORA: a failed change starts an incident; the next good deploy ends it.
  [[ -f "$STATE_DIR/$env/incident_start" ]] || date +%s > "$STATE_DIR/$env/incident_start"
  if [[ -f "$applied/release.env" ]]; then
    local prev_version port
    prev_version="$(env_value "$applied/release.env" APP_VERSION)"
    port="$(env_value "$applied/config.env" HOST_PORT)"
    compose "$env" "$applied" up -d --remove-orphans api worker
    if wait_ready "$port" "$prev_version"; then
      log "rolled back to ${prev_version:0:12}"
      write_status "$env" rolled_back "$reason" "$prev_version"
      notify high "$env rolled back" \
        "Rolled back ${version:0:12} -> ${prev_version:0:12}: $reason. The bad release won't be retried." \
        "rollback:$env:$version"
    else
      warn "previous release ${prev_version:0:12} is not ready either; manual attention needed"
      write_status "$env" degraded "rollback target not ready: $reason" "$prev_version"
      notify critical "$env is degraded" \
        "Deploy of ${version:0:12} failed ($reason) and the rollback target ${prev_version:0:12} is not ready either. Manual attention needed." \
        "degraded:$env:$version" T1489 Impact
    fi
  else
    # First-ever deploy failed: nothing to go back to. Stop the broken app
    # (keep the database volume) rather than leave it serving errors.
    compose "$env" "$STATE_DIR/$env/incoming" stop api worker || true
    write_status "$env" failed "first deploy failed, app stopped: $reason" "$version"
    notify high "$env first deploy failed" "First deploy of ${version:0:12} failed ($reason); app stopped, database kept." \
      "firstdeploy:$env:$version"
  fi
}

disk_preflight() {
  # Refuse to start a deploy that would fill the disk mid-pull. Not recorded
  # as a bad revision: it will retry once space is freed.
  local root free_mb
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  free_mb="$(df -Pm "$root" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "$free_mb" ]] || return 0
  if ((free_mb < MIN_FREE_DISK_MB)); then
    warn "only ${free_mb}MB free on $root (need $MIN_FREE_DISK_MB); not deploying"
    return 1
  fi
}

prune_images() {
  # Remove this app's images unused for PRUNE_AFTER. Images of running
  # containers are never removed, and rolling back to a pruned release simply
  # re-pulls it by digest.
  [[ "$PRUNE_IMAGES" == "true" ]] || return 0
  docker image prune --all --force \
    --filter "until=$PRUNE_AFTER" \
    --filter "label=org.opencontainers.image.title=personal-ci-cd" >/dev/null \
    || warn "image prune failed"
}

backs_up() { [[ " $BACKUP_ENVIRONMENTS " == *" $1 "* ]]; }

backup_db() {
  # backup_db <env> <release dir> <reason>: pg_dump (custom format) from the
  # env's running database, verified with pg_restore --list before it counts.
  local env="$1" dir="$2" reason="$3" version stamp out tmp entries bytes
  version="$(env_value "$dir/release.env" APP_VERSION)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR/$env"
  chmod 0700 "$BACKUP_DIR" "$BACKUP_DIR/$env"
  out="$BACKUP_DIR/$env/$stamp-$reason-${version:0:12}.dump"
  tmp="$out.partial"
  if ! compose "$env" "$dir" exec -T db pg_dump -U app -d app --format=custom > "$tmp"; then
    rm -f "$tmp"; bump "$STATE_DIR/$env/backup_failures_total"
    warn "backup ($reason) failed: pg_dump error"; return 1
  fi
  entries="$(compose "$env" "$dir" exec -T db pg_restore --list < "$tmp" 2>/dev/null | grep -c '^[0-9]' || true)"
  if [[ "${entries:-0}" -lt 1 ]]; then
    rm -f "$tmp"; bump "$STATE_DIR/$env/backup_failures_total"
    warn "backup ($reason) failed verification: pg_restore could not read it"; return 1
  fi
  mv "$tmp" "$out"
  chmod 0600 "$out"
  bytes="$(stat -c %s "$out")"
  date +%s > "$STATE_DIR/$env/last_backup"
  echo "$bytes" > "$STATE_DIR/$env/last_backup_bytes"
  # Keep the newest BACKUP_KEEP dumps.
  find "$BACKUP_DIR/$env" -maxdepth 1 -name '*.dump' -printf '%T@ %p\n' \
    | sort -rn | tail -n +"$((BACKUP_KEEP + 1))" | cut -d' ' -f2- | xargs -r rm -f
  log "backup ($reason): $(basename "$out"), $bytes bytes, $entries objects"
}

daily_backup() {
  local env="$1" applied="$STATE_DIR/$1/applied" last
  backs_up "$env" && [[ -f "$applied/release.env" ]] || return 0
  last="$(cat "$STATE_DIR/$env/last_backup" 2>/dev/null || echo 0)"
  (( $(date +%s) - last >= BACKUP_EVERY_HOURS * 3600 )) || return 0
  backup_db "$env" "$applied" daily \
    || notify medium "$env daily backup failed" "The scheduled database backup failed; see journalctl -u gitops-agent." \
         "backup:$env:$(date +%Y%m%d)"
}

heal_drift() {
  local env="$1"
  local applied="$STATE_DIR/$env/applied" running
  [[ -f "$applied/release.env" ]] || return 0
  running="$(compose "$env" "$applied" ps --status running --services 2>/dev/null | sort | tr '\n' ' ')"
  if [[ "$running" != *"api"* || "$running" != *"db"* || "$running" != *"worker"* ]]; then
    warn "drift: running services are [${running}]; restoring applied release"
    compose "$env" "$applied" up -d --remove-orphans db api worker
    bump "$STATE_DIR/$env/drift_heals_total"
    notify medium "$env drift healed" "Containers of the applied release had stopped (running: ${running:-none}); restarted them." \
      "drift:$env:$(date +%Y%m%d%H)"
  fi
}

reconcile_env() {
  local env="$1"
  CURRENT_ENV="$env"
  local src="$REPO_DIR/$env" dir="$STATE_DIR/$env" rev
  mkdir -p "$dir"

  if [[ ! -f "$src/release.env" ]]; then
    log "not promoted yet"
    return 0
  fi
  if [[ ! -f "$SECRETS_DIR/$env.env" ]]; then
    warn "missing $SECRETS_DIR/$env.env (POSTGRES_PASSWORD); skipping"
    return 0
  fi

  rev="$(git -C "$REPO_DIR" rev-parse "HEAD:$env")"
  if [[ "$rev" == "$(cat "$dir/applied.rev" 2>/dev/null)" ]]; then
    heal_drift "$env"
    return 0
  fi
  if [[ "$rev" == "$(cat "$dir/failed.rev" 2>/dev/null)" ]]; then
    return 0 # known-bad revision; wait for a new promotion or a revert
  fi

  local image version port
  image="$(env_value "$src/release.env" APP_IMAGE)"
  version="$(env_value "$src/release.env" APP_VERSION)"
  port="$(env_value "$src/config.env" HOST_PORT)"
  log "desired release ${version:0:12} ($image)"

  if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
    warn "APP_IMAGE is not pinned by digest; refusing"
    echo "$rev" > "$dir/failed.rev"
    write_status "$env" failed "image not pinned by digest" "$version"
    return 1
  fi

  # Production only accepts digests that passed staging's soak on this host.
  if [[ "$env" != "staging" ]] && ! grep -qxF "$image" "$VERIFIED_DIGESTS" 2>/dev/null; then
    log "waiting: ${version:0:12} has not yet passed staging on this host"
    write_status "$env" waiting "not yet verified in staging" "$version"
    return 0
  fi

  if ! verify_image "$image"; then
    warn "signature verification FAILED for $image"
    echo "$rev" > "$dir/failed.rev"
    write_status "$env" failed "signature verification failed" "$version"
    notify critical "Refused unsigned image ($env)" \
      "Image $image for ${version:0:12} failed Sigstore signature/SBOM verification and was NOT deployed. Either the image was not built by this repo's pipeline on main, or it was tampered with." \
      "refused:$env:$version" T1195.002 "Initial Access"
    return 1
  fi

  if ! disk_preflight; then
    write_status "$env" failed "low disk space (will retry)" "$version"
    notify medium "$env deploy blocked: low disk" "Not deploying ${version:0:12}: less than ${MIN_FREE_DISK_MB}MB free. Will retry automatically." \
      "disk:$env:$version" T1499 Impact
    return 1
  fi

  # Stage the release outside the git checkout so later fetches can't
  # change it underneath us.
  rm -rf "$dir/incoming"
  cp -a "$src" "$dir/incoming"
  write_status "$env" deploying "" "$version"

  if ! compose "$env" "$dir/incoming" pull --quiet db api worker migrate; then
    warn "image pull failed; will retry next run"
    write_status "$env" failed "pull failed (will retry)" "$version"
    return 1
  fi

  # Snapshot the database before the schema changes, so a bad migration is
  # recoverable (deploy/agent/restore-db.sh). No backup, no migration.
  if backs_up "$env" && [[ -f "$dir/applied/release.env" ]]; then
    if ! backup_db "$env" "$dir/applied" "pre-${version:0:12}"; then
      write_status "$env" failed "pre-migration backup failed (will retry)" "$version"
      notify high "$env deploy blocked: backup failed" \
        "Could not take a verified database backup before migrating to ${version:0:12}; not deploying. Will retry." \
        "backup:$env:$version"
      return 1
    fi
  fi

  # Migrations run while the previous release keeps serving. A failure here
  # leaves production exactly as it was.
  log "running migrations"
  if ! compose "$env" "$dir/incoming" run --rm migrate; then
    warn "migration failed; current release left untouched"
    echo "$rev" > "$dir/failed.rev"
    write_status "$env" failed "migration failed; previous release still serving" "$version"
    notify high "$env migration failed" "Database migration for ${version:0:12} failed; the previous release is still serving untouched." \
      "migration:$env:$version"
    return 1
  fi

  log "replacing app containers"
  if ! compose "$env" "$dir/incoming" up -d --remove-orphans db api worker; then
    rollback "$env" "compose up failed" "$rev" "$version"
    return 1
  fi
  if ! wait_ready "$port" "$version"; then
    rollback "$env" "not ready within ${READY_TIMEOUT}s" "$rev" "$version"
    return 1
  fi
  if ! soak "$env" "$port" "$version"; then
    rollback "$env" "failed post-deploy soak" "$rev" "$version"
    return 1
  fi

  rm -rf "$dir/applied"
  mv "$dir/incoming" "$dir/applied"
  echo "$rev" > "$dir/applied.rev"
  rm -f "$dir/failed.rev"
  if [[ "$env" == "staging" ]]; then
    grep -qxF "$image" "$VERIFIED_DIGESTS" 2>/dev/null || echo "$image" >> "$VERIFIED_DIGESTS"
  fi
  bump "$dir/deploys_total"
  date +%s > "$dir/last_deploy"
  record_dora "$env" "$dir/applied/release.env"
  prune_images
  log "deployed ${version:0:12}"
  write_status "$env" deployed "" "$version"
  notify info "$env deployed ${version:0:12}" "$env: deployed ${version:0:12} (signed, migrated, soaked)"
}

add_to() { # add_to <file> <number>: persisted running sum
  local cur; cur="$(cat "$1" 2>/dev/null || echo 0)"
  echo $((cur + $2)) > "$1"
}

record_dora() {
  # Lead time for changes (commit -> running in this env) and time to restore
  # service after a failed change, as running sums for Prometheus summaries.
  local env="$1" release="$2" now committed started
  local d="$STATE_DIR/$env"
  now="$(date +%s)"
  committed="$(env_value "$release" COMMIT_TIMESTAMP)"
  if [[ "$committed" =~ ^[0-9]+$ ]] && ((committed > 0 && committed <= now)); then
    add_to "$d/lead_time_sum" $((now - committed))
    bump "$d/lead_time_count"
  fi
  if [[ -f "$d/incident_start" ]]; then
    started="$(cat "$d/incident_start")"
    add_to "$d/recovery_sum" $((now - started))
    bump "$d/recovery_count"
    rm -f "$d/incident_start"
  fi
}

write_metrics() {
  # Export agent state for Prometheus via node-exporter's textfile collector.
  # Written atomically (tmp + rename) so a scrape never sees half a file.
  local rc="$1" started="$2"
  mkdir -p "$METRICS_DIR"
  python3 - "$STATE_DIR" "$ENVIRONMENTS" "$rc" "$started" > "$METRICS_DIR/gitops.prom.$$" <<'PY'
import json, os, sys, time
state_dir, envs, rc, started = sys.argv[1], sys.argv[2].split(), int(sys.argv[3]), float(sys.argv[4])
states = ["deployed", "deploying", "waiting", "rolled_back", "failed", "degraded"]

def read(path, default=0.0):
    try:
        return float(open(path).read().strip())
    except (OSError, ValueError):
        return default

def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")

out = []
def metric(name, help_, type_, samples):
    out.append(f"# HELP {name} {help_}")
    out.append(f"# TYPE {name} {type_}")
    for labels, value in samples:
        lbl = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
        out.append(f"{name}{{{lbl}}} {value}" if lbl else f"{name} {value}")

now = time.time()
metric("gitops_agent_last_run_timestamp_seconds", "When the agent last finished a run", "gauge", [({}, now)])
metric("gitops_agent_last_run_success", "1 if every environment reconciled cleanly", "gauge", [({}, int(rc == 0))])
metric("gitops_agent_last_run_duration_seconds", "Duration of the last run", "gauge", [({}, round(now - started, 3))])

state_s, info_s, deploy_ts, deploys, rollbacks, heals = [], [], [], [], [], []
backup_ts, backup_bytes, backup_fail = [], [], []
lead_sum, lead_cnt, rec_sum, rec_cnt, open_incident = [], [], [], [], []
for env in envs:
    d = os.path.join(state_dir, env)
    try:
        status = json.load(open(os.path.join(d, "status.json")))
    except (OSError, ValueError):
        status = {}
    current = status.get("state", "")
    for s in states:
        state_s.append(({"env": env, "state": s}, int(s == current)))
    if status.get("version"):
        info_s.append(({"env": env, "version": status["version"], "detail": status.get("detail", "")}, 1))
    deploy_ts.append(({"env": env}, read(os.path.join(d, "last_deploy"))))
    deploys.append(({"env": env}, read(os.path.join(d, "deploys_total"))))
    rollbacks.append(({"env": env}, read(os.path.join(d, "rollbacks_total"))))
    heals.append(({"env": env}, read(os.path.join(d, "drift_heals_total"))))
    lead_sum.append(({"env": env}, read(os.path.join(d, "lead_time_sum"))))
    lead_cnt.append(({"env": env}, read(os.path.join(d, "lead_time_count"))))
    rec_sum.append(({"env": env}, read(os.path.join(d, "recovery_sum"))))
    rec_cnt.append(({"env": env}, read(os.path.join(d, "recovery_count"))))
    open_incident.append(({"env": env}, read(os.path.join(d, "incident_start"))))
    if os.path.exists(os.path.join(d, "last_backup")) or os.path.exists(os.path.join(d, "backup_failures_total")):
        backup_ts.append(({"env": env}, read(os.path.join(d, "last_backup"))))
        backup_bytes.append(({"env": env}, read(os.path.join(d, "last_backup_bytes"))))
        backup_fail.append(({"env": env}, read(os.path.join(d, "backup_failures_total"))))

metric("gitops_environment_state", "Current reconcile state per environment", "gauge", state_s)
metric("gitops_environment_info", "Version the agent last acted on", "gauge", info_s)
metric("gitops_last_deploy_timestamp_seconds", "When the last successful deploy finished", "gauge", deploy_ts)
metric("gitops_deploys_total", "Successful deploys", "counter", deploys)
metric("gitops_rollbacks_total", "Automatic rollbacks", "counter", rollbacks)
metric("gitops_drift_heals_total", "Times the applied release was restarted after drift", "counter", heals)
# DORA. Summaries are exposed as _sum/_count pairs so rate() works over any window.
out.append("# HELP gitops_lead_time_seconds Commit-to-running time of each successful deploy")
out.append("# TYPE gitops_lead_time_seconds summary")
out += [f'gitops_lead_time_seconds_sum{{env="{l["env"]}"}} {v}' for l, v in lead_sum]
out += [f'gitops_lead_time_seconds_count{{env="{l["env"]}"}} {v}' for l, v in lead_cnt]
out.append("# HELP gitops_recovery_seconds Time from a failed change to the next successful deploy")
out.append("# TYPE gitops_recovery_seconds summary")
out += [f'gitops_recovery_seconds_sum{{env="{l["env"]}"}} {v}' for l, v in rec_sum]
out += [f'gitops_recovery_seconds_count{{env="{l["env"]}"}} {v}' for l, v in rec_cnt]
metric("gitops_incident_open_since_timestamp_seconds", "Start of an unrecovered failed change (0 = none)", "gauge", open_incident)
metric("gitops_backup_last_timestamp_seconds", "When the last verified database backup finished", "gauge", backup_ts)
metric("gitops_backup_last_size_bytes", "Size of the last verified database backup", "gauge", backup_bytes)
metric("gitops_backup_failures_total", "Database backups that failed or could not be verified", "counter", backup_fail)
print("\n".join(out))
PY
  chmod 0644 "$METRICS_DIR/gitops.prom.$$"
  mv -f "$METRICS_DIR/gitops.prom.$$" "$METRICS_DIR/gitops.prom"
}

main() {
  local started; started="$(date +%s)"
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/lock"
  if ! flock -n 9; then
    log "another run is in progress"
    exit 0
  fi

  check_downtime || warn "downtime check failed"

  docker network inspect observability >/dev/null 2>&1 || docker network create observability >/dev/null

  local env rc=0
  if sync_repo; then
    for env in $ENVIRONMENTS; do
      reconcile_env "$env" || rc=1
      CURRENT_ENV="$env"
      daily_backup "$env" || true
      CURRENT_ENV=""
    done
  fi
  write_metrics "$rc" "$started" || warn "could not write metrics"
  date +%s > "$STATE_DIR/last-alive"
  heartbeat
  exit "$rc"
}

main "$@"
