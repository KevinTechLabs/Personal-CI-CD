#!/usr/bin/env bash
# Restore an environment's database from a backup taken by the GitOps agent.
#
#   sudo deploy/agent/restore-db.sh production            # list backups
#   sudo deploy/agent/restore-db.sh production <file>     # restore one
#
# What it does:
#   1. takes a safety backup of the current database (so the restore is undoable)
#   2. pauses the GitOps agent and stops the api + worker (database stays up)
#   3. restores in a single transaction (all or nothing)
#   4. starts api + worker again, resumes the agent, checks /ready
#
# A dump is tied to the schema of the release that made it (the release is in
# its file name). If you restore across a migration, also roll the release
# back to that version (docs/OPERATIONS.md → Roll back).

set -euo pipefail

CONFIG_FILE="${GITOPS_AGENT_CONFIG:-/etc/gitops-agent/agent.env}"
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
STATE_DIR="${STATE_DIR:-/var/lib/gitops-agent}"
SECRETS_DIR="${SECRETS_DIR:-/etc/gitops-agent/secrets}"
BACKUP_DIR="${BACKUP_DIR:-$STATE_DIR/backups}"

env="${1:?usage: restore-db.sh <staging|production> [backup file]}"
dump="${2:-}"
[[ "$env" =~ ^[a-z]+$ ]] || { echo "bad environment name" >&2; exit 2; }
applied="$STATE_DIR/$env/applied"
[[ -f "$applied/release.env" ]] || { echo "$env has never been deployed on this host" >&2; exit 1; }

if [[ -z "$dump" ]]; then
  echo "Backups for $env (newest first):"
  find "$BACKUP_DIR/$env" -maxdepth 1 -name '*.dump' -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' 2>/dev/null \
    | sort -r || true
  echo
  echo "Restore one with: sudo $0 $env <path>"
  exit 0
fi
[[ -f "$dump" ]] || { echo "no such file: $dump" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

compose() {
  docker compose --project-name "cicd-$env" --project-directory "$applied" \
    --file "$applied/compose.yaml" --env-file "$applied/config.env" \
    --env-file "$applied/release.env" --env-file "$SECRETS_DIR/$env.env" "$@"
}

docker compose version >/dev/null
compose exec -T db pg_restore --list < "$dump" >/dev/null \
  || { echo "$dump is not a readable pg_dump archive" >&2; exit 1; }

port="$(sed -n 's/^HOST_PORT=//p' "$applied/config.env")"
echo "About to REPLACE the $env database with:"
echo "  $dump"
echo "The api and worker will be stopped while it runs (a few seconds for a small database)."
read -rp "Type the environment name to continue: " answer
[[ "$answer" == "$env" ]] || { echo "aborted"; exit 1; }

safety="$BACKUP_DIR/$env/$(date -u +%Y%m%dT%H%M%SZ)-pre-restore.dump"
echo "==> Safety backup: $safety"
mkdir -p "$BACKUP_DIR/$env"
compose exec -T db pg_dump -U app -d app --format=custom > "$safety"
chmod 0600 "$safety"

echo "==> Pausing the GitOps agent and stopping api + worker"
systemctl stop gitops-agent.timer 2>/dev/null || true
resume() {
  compose up -d api worker >/dev/null 2>&1 || true
  systemctl start gitops-agent.timer 2>/dev/null || true
}
trap resume EXIT
compose stop api worker

echo "==> Restoring (single transaction)"
compose exec -T db pg_restore -U app -d app --clean --if-exists --no-owner --single-transaction < "$dump"

echo "==> Starting api + worker"
trap - EXIT
resume
for _ in $(seq 1 30); do
  if curl -fsS -m 3 "http://127.0.0.1:$port/ready" >/dev/null 2>&1; then
    echo "==> $env is ready:"
    curl -fsS "http://127.0.0.1:$port/ready" | python3 -m json.tool
    echo "If anything is wrong, restore the safety backup: sudo $0 $env $safety"
    exit 0
  fi
  sleep 2
done
echo "$env did not become ready. Check: docker compose -p cicd-$env logs api" >&2
echo "Undo with: sudo $0 $env $safety" >&2
exit 1
