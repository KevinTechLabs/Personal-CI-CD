#!/usr/bin/env bash
# One-time install of the GitOps agent on AI-LAB. Idempotent; re-run to
# upgrade the agent script. Run from a checkout of this repo:
#
#   sudo deploy/agent/install.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"

for cmd in docker git curl python3 flock cosign; do
  command -v "$cmd" >/dev/null || { echo "missing dependency: $cmd (see docs/OPERATIONS.md)" >&2; exit 1; }
done
docker compose version >/dev/null || { echo "docker compose plugin missing" >&2; exit 1; }

id gitops >/dev/null 2>&1 || useradd --system --home-dir /var/lib/gitops-agent --shell /usr/sbin/nologin gitops
usermod -aG docker gitops

install -d -m 0755 /opt/gitops-agent
install -m 0755 "$here/gitops-agent.sh" /opt/gitops-agent/gitops-agent.sh
install -d -m 0750 -o gitops -g gitops /var/lib/gitops-agent
install -d -m 0750 -o root -g gitops /etc/gitops-agent /etc/gitops-agent/secrets

if [[ ! -f /etc/gitops-agent/agent.env ]]; then
  install -m 0640 -o root -g gitops "$here/agent.env.example" /etc/gitops-agent/agent.env
  echo "created /etc/gitops-agent/agent.env; review it"
fi

for env in staging production; do
  f="/etc/gitops-agent/secrets/$env.env"
  if [[ ! -f "$f" ]]; then
    # Hex keeps the password URL-safe inside DATABASE_URL.
    printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)" > "$f"
    chown root:gitops "$f"; chmod 0640 "$f"
    echo "generated $f"
  fi
done

install -m 0644 "$here/gitops-agent.service" /etc/systemd/system/gitops-agent.service
install -m 0644 "$here/gitops-agent.timer"   /etc/systemd/system/gitops-agent.timer
systemctl daemon-reload
systemctl enable --now gitops-agent.timer

echo "installed. Follow along with: journalctl -fu gitops-agent"
