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
#   4. replaces the app containers and waits for /ready + the expected version
#   5. soaks: sends synthetic traffic and watches the error-ratio SLO in
#      Prometheus; on breach (or failed readiness) it rolls back to the last
#      good release and remembers the bad revision so it won't retry it
#
# It also self-heals drift: if the applied release's containers are not
# running, it brings them back.
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
NOTIFY_URL="${NOTIFY_URL:-}"

REPO_DIR="$STATE_DIR/repo"
VERIFIED_DIGESTS="$STATE_DIR/verified-digests"

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${CURRENT_ENV:-agent}" "$*"; }
warn() { log "WARN: $*" >&2; }

notify() {
  # Optional: any webhook that accepts a plain-text POST (e.g. ntfy.sh topic).
  [[ -n "$NOTIFY_URL" ]] || return 0
  curl -fsS -m 10 -d "[$HOSTNAME/${CURRENT_ENV:-agent}] $*" "$NOTIFY_URL" >/dev/null || warn "notify failed"
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

wait_ready() {
  # Ready = /ready is 200 and /version reports the release we just deployed.
  local port="$1" want_version="$2" deadline=$((SECONDS + READY_TIMEOUT)) got
  while ((SECONDS < deadline)); do
    if curl -fsS -m 3 "http://127.0.0.1:$port/ready" >/dev/null 2>&1; then
      got="$(curl -fsS -m 3 "http://127.0.0.1:$port/version" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
      [[ "$got" == "$want_version" ]] && return 0
    fi
    sleep 2
  done
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
  # Watch the new release; return non-zero on SLO breach or readiness loss.
  local env="$1" port="$2" deadline=$((SECONDS + SOAK_SECONDS)) ratio
  log "soaking for ${SOAK_SECONDS}s (max error ratio $MAX_ERROR_RATIO)"
  while ((SECONDS < deadline)); do
    synthetic_traffic "$port"
    if ! curl -fsS -m 3 "http://127.0.0.1:$port/ready" >/dev/null 2>&1; then
      warn "readiness lost during soak"
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
  if [[ -f "$applied/release.env" ]]; then
    local prev_version port
    prev_version="$(env_value "$applied/release.env" APP_VERSION)"
    port="$(env_value "$applied/config.env" HOST_PORT)"
    compose "$env" "$applied" up -d --remove-orphans api worker
    if wait_ready "$port" "$prev_version"; then
      log "rolled back to ${prev_version:0:12}"
      write_status "$env" rolled_back "$reason" "$prev_version"
      notify "ROLLED BACK ${version:0:12} -> ${prev_version:0:12}: $reason"
    else
      warn "previous release ${prev_version:0:12} is not ready either; manual attention needed"
      write_status "$env" degraded "rollback target not ready: $reason" "$prev_version"
      notify "DEGRADED: rollback to ${prev_version:0:12} not ready ($reason)"
    fi
  else
    # First-ever deploy failed: nothing to go back to. Stop the broken app
    # (keep the database volume) rather than leave it serving errors.
    compose "$env" "$STATE_DIR/$env/incoming" stop api worker || true
    write_status "$env" failed "first deploy failed, app stopped: $reason" "$version"
    notify "FAILED first deploy of ${version:0:12}: $reason"
  fi
}

heal_drift() {
  local env="$1" applied="$STATE_DIR/$env/applied" running
  [[ -f "$applied/release.env" ]] || return 0
  running="$(compose "$env" "$applied" ps --status running --services 2>/dev/null | sort | tr '\n' ' ')"
  if [[ "$running" != *"api"* || "$running" != *"db"* || "$running" != *"worker"* ]]; then
    warn "drift: running services are [${running}]; restoring applied release"
    compose "$env" "$applied" up -d --remove-orphans db api worker
    notify "healed drift (running: ${running:-none})"
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
    notify "REFUSED ${version:0:12}: signature verification failed"
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

  # Migrations run while the previous release keeps serving. A failure here
  # leaves production exactly as it was.
  log "running migrations"
  if ! compose "$env" "$dir/incoming" run --rm migrate; then
    warn "migration failed; current release left untouched"
    echo "$rev" > "$dir/failed.rev"
    write_status "$env" failed "migration failed; previous release still serving" "$version"
    notify "FAILED ${version:0:12}: migration failed, previous release untouched"
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
  if ! soak "$env" "$port"; then
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
  log "deployed ${version:0:12}"
  write_status "$env" deployed "" "$version"
  notify "deployed ${version:0:12}"
}

main() {
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/lock"
  if ! flock -n 9; then
    log "another run is in progress"
    exit 0
  fi

  docker network inspect observability >/dev/null 2>&1 || docker network create observability >/dev/null
  sync_repo || exit 0

  local env rc=0
  for env in $ENVIRONMENTS; do
    reconcile_env "$env" || rc=1
    CURRENT_ENV=""
  done
  exit "$rc"
}

main "$@"
