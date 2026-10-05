#!/usr/bin/env bash
# One-time alert setup on AI-LAB: send everything to Sentinel
# (KevinTechLabs/Homelab-Soc-Dashboard, v1.7.0 or newer).
#
#   sudo deploy/observability/configure-alerts.sh --sentinel http://<sentinel-ip>:8088
#
# You'll be asked for Sentinel's *ingest key* (on the Sentinel server:
# `sudo cat /etc/sentinel/ingest_token`). It can only push alerts in, so a copy
# on this machine can't block addresses or change your router.
#
# Writes (none of it committed):
#   deploy/observability/secrets/sentinel_url, sentinel_key   read by Alertmanager
#   /etc/gitops-agent/sentinel_key + SENTINEL_URL in agent.env  deploy events
# then sends a test event so you can see it arrive in Sentinel.
#
# Options:
#   --key-file <path>   read the key from a file instead of prompting
#   --source <name>     how this host appears in Sentinel (default: ai-lab;
#                       must match `host` in prometheus/prometheus.yml)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
secrets="$here/secrets"
sentinel="" key_file="" source="ai-lab"
agent_dir=/etc/gitops-agent

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sentinel) sentinel="${2%/}"; shift 2 ;;
    --key-file) key_file="$2"; shift 2 ;;
    --source) source="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run with sudo (secrets are owned by the containers' users)" >&2; exit 1; }
[[ "$sentinel" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] \
  || { echo "--sentinel must look like http://192.168.1.50:8088 (no path)" >&2; exit 2; }
[[ "$source" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "--source: letters, digits, . _ - only" >&2; exit 2; }

if [[ -n "$key_file" ]]; then
  key="$(tr -d '[:space:]' < "$key_file")"
else
  read -rsp "Sentinel ingest key (sudo cat /etc/sentinel/ingest_token on the Sentinel server): " key
  echo
fi
[[ "$key" =~ ^[A-Za-z0-9_-]{16,}$ ]] || { echo "that doesn't look like a Sentinel key" >&2; exit 2; }

# 1. Prove the URL and key work before writing anything.
echo "==> Testing $sentinel"
code="$(curl -sS -o /tmp/sentinel-test.$$ -w '%{http_code}' -m 10 \
  -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
  -d "{\"source\":\"$source\",\"kind\":\"GitOps\",\"level\":\"info\",\"title\":\"Alerting connected\",\"text\":\"Alertmanager and the GitOps agent on $source are now reporting to Sentinel\"}" \
  "$sentinel/api/ingest/event" || true)"
body="$(cat /tmp/sentinel-test.$$ 2>/dev/null || true)"; rm -f /tmp/sentinel-test.$$
case "$code" in
  200) echo "    ok: test event accepted (look for it in Sentinel's activity feed)" ;;
  401) echo "    Sentinel rejected the key" >&2; exit 1 ;;
  404) echo "    Sentinel answered but has no ingest endpoint; update it to v1.7.0+ (re-run its install-server.sh)" >&2; exit 1 ;;
  000) echo "    could not reach $sentinel (firewall? wrong port? is nginx up on the Sentinel server?)" >&2; exit 1 ;;
  *)   echo "    unexpected HTTP $code: $body" >&2; exit 1 ;;
esac

# 2. Alertmanager's copies. It runs as nobody (65534) inside its container.
install -d -m 0755 "$secrets"
umask 077
printf '%s/api/ingest/alertmanager\n' "$sentinel" > "$secrets/sentinel_url"
printf '%s\n' "$key" > "$secrets/sentinel_key"
chown 65534:65534 "$secrets/sentinel_url" "$secrets/sentinel_key"
chmod 0400 "$secrets/sentinel_url" "$secrets/sentinel_key"
echo "==> Wrote Alertmanager secrets in $secrets"

# 3. The GitOps agent's copy (deploy / rollback / refused-image events).
if [[ -d "$agent_dir" ]]; then
  printf '%s\n' "$key" > "$agent_dir/sentinel_key"
  chown root:gitops "$agent_dir/sentinel_key" 2>/dev/null || true
  chmod 0640 "$agent_dir/sentinel_key"
  conf="$agent_dir/agent.env"
  for kv in "SENTINEL_URL=$sentinel" "SENTINEL_KEY_FILE=$agent_dir/sentinel_key" "SENTINEL_SOURCE=$source"; do
    k="${kv%%=*}"
    if grep -q "^$k=" "$conf" 2>/dev/null; then
      sed -i "s#^$k=.*#$kv#" "$conf"
    else
      printf '%s\n' "$kv" >> "$conf"
    fi
  done
  echo "==> Configured the GitOps agent ($conf)"
else
  echo "==> GitOps agent not installed yet; re-run this after deploy/agent/install.sh"
fi

cat <<EOF

Done. Apply with:
  cd $here && docker compose --env-file grafana.env up -d && docker compose restart alertmanager

Within a minute Sentinel starts receiving the Watchdog heartbeat from "$source".
From then on, if this host goes quiet for 5 minutes, Sentinel raises
"Monitoring on $source stopped reporting".
EOF
