#!/usr/bin/env bash
# One-time alert setup on AI-LAB. Writes the two secret files Alertmanager
# reads (never committed) and optionally sends a test notification.
#
#   deploy/observability/configure-alerts.sh \
#     --ntfy https://ntfy.sh/<your-private-topic> \
#     --healthchecks https://hc-ping.com/<uuid> \
#     --test
#
#   --ntfy          where alerts are pushed. Pick a long, unguessable topic
#                   name: anyone who knows it can read your alerts. Install the
#                   ntfy app on your phone and subscribe to the same topic.
#   --healthchecks  ping URL of a healthchecks.io check (free). Configure the
#                   check with Period 1 minute, Grace 5 minutes, and connect
#                   your phone/email there. If AI-LAB stops pinging, that is
#                   the alert that the whole box (or its monitoring) is down.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
secrets="$here/secrets"
ntfy="" healthchecks="" test=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ntfy) ntfy="$2"; shift 2 ;;
    --healthchecks) healthchecks="$2"; shift 2 ;;
    --test) test=true; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$ntfy" =~ ^https://[^/]+/[A-Za-z0-9_-]{8,}$ ]] \
  || { echo "--ntfy must look like https://ntfy.sh/<topic> (topic: 8+ letters, digits, _ or -)" >&2; exit 2; }
[[ "$healthchecks" =~ ^https://[^[:space:]]+$ ]] \
  || { echo "--healthchecks must be an https ping URL" >&2; exit 2; }

# ntfy renders Alertmanager's JSON webhook through these inline templates
# (title, message, priority), so alerts read like sentences, not JSON.
ntfy_alert_url="$(python3 - "$ntfy" <<'PY'
import sys, urllib.parse
base = sys.argv[1]
title = ('{{if eq .status "resolved"}}RESOLVED{{else}}FIRING{{end}}: '
         '{{.commonLabels.alertname}}{{if .commonLabels.env}} ({{.commonLabels.env}}){{end}}')
message = '{{range .alerts}}{{.annotations.summary}}{{"\\n"}}{{end}}'
priority = ('{{if eq .status "resolved"}}2{{else if eq .commonLabels.severity "page"}}5'
            '{{else}}3{{end}}')
print(base + "?" + urllib.parse.urlencode({"tpl": "yes", "t": title, "m": message, "p": priority}))
PY
)"

# Alertmanager runs as `nobody` inside its container, so the bind-mounted
# files must be world-readable. Keep this box single-user, or move them to
# Docker secrets if that ever changes.
install -d -m 0755 "$secrets"
umask 022
printf '%s\n' "$ntfy_alert_url" > "$secrets/ntfy_url"
printf '%s\n' "$healthchecks" > "$secrets/healthchecks_url"
echo "wrote $secrets/ntfy_url and $secrets/healthchecks_url"

if $test; then
  curl -fsS -m 10 -H "Title: AI-LAB alerting test" -H "Tags: white_check_mark" \
    -d "If you can read this on your phone, alert delivery works." "$ntfy" >/dev/null \
    && echo "sent test notification to $ntfy"
  curl -fsS -m 10 "$healthchecks" >/dev/null && echo "pinged healthchecks.io"
fi

cat <<EOF

Next:
  - Apply:  cd $here && docker compose --env-file grafana.env up -d && docker compose restart alertmanager
  - Deploy events from the GitOps agent: set NOTIFY_URL=$ntfy in /etc/gitops-agent/agent.env
EOF
