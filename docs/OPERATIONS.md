# Operations runbook

## Hosts

| Host | Role |
|---|---|
| **REACTOR** | development workstation; changes are pushed from here |
| **AI-LAB** | runs staging (:8081), production (:8080), the GitOps agent, and the monitoring stack: Prometheus (localhost:9090), Alertmanager (localhost:9093), blackbox + node-exporter (internal), Grafana (:3000) |

---

## One-time setup

### 1. Generate the lockfile (REACTOR)

CI installs with `uv sync --locked`, so `uv.lock` must exist before the first push.

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh   # or: pipx install uv
cd ~/projects/my-cicd-project
git checkout v2-advanced-pipeline
uv lock
git add uv.lock && git commit -m "Add uv.lock" && git push
```

Run `uv lock` again whenever you change dependencies in `pyproject.toml`.

### 2. GitHub settings

**Settings → Environments**

- `staging`: no protection rules.
- `production`: **Required reviewers** → add yourself. Under *Deployment
  branches and tags*, allow `main` only. This is the manual approval gate.

**Settings → Rules → Rulesets**

- `main`: require status checks *Lint, SAST, dependency audit, secret scan*,
  *Tests (Postgres integration)*, *Build, scan, smoke test* and *CodeQL*;
  block force pushes. Working solo, you can still merge your own PRs.
- `environments`: block force pushes and deletions. This keeps the
  deployment history (your audit log) intact while still letting the
  pipeline's bot commit.

**Settings → Code security**: if CodeQL *default setup* is on, switch to
*advanced*, since this repo ships its own `codeql.yml`. Enable Dependabot alerts.

**Settings → Actions → General**: workflow permissions *read-only*. Every
job declares what it needs.

### 3. GHCR package visibility

The organization's first publish creates `ghcr.io/kevintechlabs/my-cicd-project`.
New packages start **private**, and AI-LAB pulls anonymously, so after the
first green `main` run:

*Your org → Packages → my-cicd-project → Package settings → Change visibility → Public.*

(v1's package lived under the old owner `marcottejkevin-art`; it can be
deleted once v2 is running.)

### 4. AI-LAB: retire v1

The self-hosted runner is no longer used. Remove it so nothing from this
public repo can run jobs on the homelab:

```bash
cd ~/actions-runner
sudo ./svc.sh stop
sudo ./svc.sh uninstall
./config.sh remove --token <token from Settings → Actions → Runners → kevin-ai → Remove>
```

Leave the v1 container on :8080 running for now; it's removed in step 7.

### 5. AI-LAB: install cosign

The agent refuses unsigned images, so it needs cosign (same major version as CI):

```bash
curl -fsSLO https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign-linux-amd64
curl -fsSLO https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign_checksums.txt
grep ' cosign-linux-amd64$' cosign_checksums.txt | sha256sum -c -
sudo install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

### 6. AI-LAB: install the agent and observability stack

```bash
git clone https://github.com/KevinTechLabs/Personal-CI-CD.git ~/personal-ci-cd
cd ~/personal-ci-cd
sudo deploy/agent/install.sh          # user, dirs, secrets, systemd timer

# Alerting (see "Set up alerts to your phone" below first)
deploy/observability/configure-alerts.sh \
  --ntfy https://ntfy.sh/<your-private-topic> \
  --healthchecks https://hc-ping.com/<uuid> --test

# Monitoring stack
cp deploy/observability/grafana.env.example deploy/observability/grafana.env
$EDITOR deploy/observability/grafana.env    # set a real password
cd deploy/observability && docker compose --env-file grafana.env up -d
```

Review `/etc/gitops-agent/agent.env` and set `NOTIFY_URL` to the same ntfy
topic, so deploy and rollback events reach your phone too. The installer
generates a Postgres password per environment in `/etc/gitops-agent/secrets/`.

#### Set up alerts to your phone (about 5 minutes, free)

1. **ntfy:** install the ntfy app on your phone and subscribe to a topic with
   a long, unguessable name (e.g. `ailab-alerts-` + 12 random characters).
   Anyone who knows the name can read it.
2. **healthchecks.io:** create a free account and a check named `AI-LAB
   monitoring` with **Period 1 minute, Grace 5 minutes**. Under
   *Integrations*, add your email and/or the ntfy app. Copy the check's
   ping URL.
3. Run `configure-alerts.sh` with both (above). `--test` sends a test push
   and the first ping.
4. After `docker compose up -d`, the healthchecks.io check turns green
   within a minute. That's the Watchdog alert arriving. If AI-LAB ever stops
   pinging, healthchecks.io tells you.

Watch it work:

```bash
journalctl -fu gitops-agent
```

### 7. First production deploy

1. Merge to `main`. Staging deploys automatically. Check http://ai-lab:8081
   and the Grafana *Platform health* dashboard.
2. Free port 8080: `docker rm -f my-cicd-project` (the v1 container).
3. Approve the *Promote to production* job in the workflow run.
4. Within a minute the agent deploys production on :8080.

---

## Day-to-day

### Ship a change

```bash
git checkout -b my-change
# edit, then:
make lint && make test
git push -u origin my-change     # open a PR: quality + tests + build/scan/smoke run
# merge → staging deploys itself → approve production when happy
```

### Where is each environment?

```bash
cat /var/lib/gitops-agent/staging/status.json
cat /var/lib/gitops-agent/production/status.json
curl -s localhost:8081/version; curl -s localhost:8080/version
git log --oneline origin/environments      # full deployment history
```

`state` is one of `deployed`, `deploying`, `waiting` (production awaiting a
staging-verified digest), `rolled_back`, `failed`, `degraded`.

### Is everything healthy?

```bash
curl -s localhost:8081/ready | python3 -m json.tool   # per-dependency report
curl -s localhost:9093/api/v2/alerts | python3 -c 'import json,sys; [print(a["labels"]["alertname"], a["labels"].get("env","")) for a in json.load(sys.stdin)]'
```

Or open Grafana → *Personal CI/CD: Platform health*. The Watchdog alert is
always listed (that's the dead man's switch working); anything else is real.

### Silence an alert during maintenance

```bash
docker exec observability-alertmanager-1 amtool --alertmanager.url=http://localhost:9093 \
  silence add alertname=EndpointDown env=staging --duration=1h --comment="planned work"
```

### Scheduled security scan

Runs Monday and Thursday (and on demand: *Actions → Scheduled security scan →
Run workflow*). If it finds a problem it opens one issue labeled
`security-scan`, comments on each repeat, and closes it when a run passes.
Usual fix: merge the Dependabot PR for the flagged package (or bump it
yourself, `uv lock`, push) and let it flow through staging → production.

### Roll back

Rollback is a Git operation, like every other change:

```bash
git fetch origin environments
git checkout environments
git log --oneline -5                      # find the promotion to undo
git revert <commit>
git push origin environments
```

The agent applies the previous release within a minute. (The ruleset allows
this: it blocks force pushes, not new commits.)

### Retry a revision the agent marked as failed

If a failure was environmental (e.g. registry outage) rather than the release:

```bash
sudo rm /var/lib/gitops-agent/<env>/failed.rev
sudo systemctl start gitops-agent
```

### Pause deployments

```bash
sudo systemctl stop gitops-agent.timer     # running stacks are untouched
sudo systemctl start gitops-agent.timer
```

### Demonstrate auto-rollback

Set `CHAOS_ERROR_RATE=0.5` in `deploy/compose/staging.env`, merge, and watch
the journal and Grafana: the agent detects the SLO breach during its soak
and rolls staging back. Set it back to `0` to recover. Health probes are
exempt from injected faults, so this exercises the SLO path specifically.

### Add a database migration

```bash
uv run alembic revision -m "add priority to tasks"
```

It runs before the new code starts, while the old release is serving, so
**expand only**: add nullable columns and new tables. Remove old columns in a
later release. See ARCHITECTURE.md §4.

---

## Troubleshooting

| Symptom | Look at |
|---|---|
| Production stuck `waiting` | Staging hasn't passed that digest on AI-LAB. Check staging's status and journal. |
| `signature verification failed` | `COSIGN_IDENTITY_REGEXP` in agent.env vs. the repo/workflow name; cosign version; AI-LAB's clock. |
| Pull fails with `unauthorized` | GHCR package still private (setup step 3). |
| `migration failed` | `docker compose -p cicd-<env> logs migrate`. The old release is still serving. |
| Soak keeps rolling back | Grafana error-ratio panel; `docker compose -p cicd-<env> logs api`. |
| Deploy rolled back: `no heartbeat from a <sha> worker` | The new worker isn't starting: `docker compose -p cicd-<env> logs worker`. |
| `low disk space (will retry)` | `docker system df`; free space and the agent retries on its own. Lower `PRUNE_AFTER` if images pile up. |
| `/ready` says `degraded` | Read which check: `worker` (worker down, see logs), `queue` (worker too slow or stuck), `database` (slow). Degraded still serves traffic. |
| No push notifications | `docker compose -f deploy/observability/compose.yaml logs alertmanager`; rerun `configure-alerts.sh --test`; check the ntfy topic name on your phone. |
| healthchecks.io says "down" | Alertmanager or Prometheus isn't running, or AI-LAB is offline: `docker compose -f deploy/observability/compose.yaml ps`. |
| `GitOpsAgentStale` | `systemctl status gitops-agent.timer`, `journalctl -u gitops-agent -n 50`. |
| `GitOpsAgentMetricsMissing` | Agent installed before this release: rerun `sudo deploy/agent/install.sh` (creates the metrics dir), then restart node-exporter. |
| `DeployDependencyUnreachable` | AI-LAB can't reach GHCR / GitHub / Sigstore: check DNS, internet, Tailscale exit-node settings. |
| `HostClockSkew` | `timedatectl`; enable NTP (`sudo timedatectl set-ntp true`). Signature checks fail on a wrong clock. |
| `Prometheus unavailable` warnings | `docker compose -f deploy/observability/compose.yaml ps`; soak falls back to readiness-only unless `REQUIRE_PROMETHEUS=true`. |
| CI `uv lock --check` fails | Dependencies changed without re-locking: run `uv lock` and commit. |
| Stack logs | `docker compose -p cicd-staging logs -f api worker` |

---

## v1 history

Lessons from v1 that shaped v2:

- **GHCR auth**: a PAT was tried for pulls before confirming the package was
  public. v2 keeps anonymous pulls (set the new package public, step 3).
- **Trivy findings from tooling**: `msgpack`/`setuptools` HIGHs came from
  pip's vendored metadata, not the app. Fixed by removing pip/setuptools from
  the runtime image rather than weakening the gate. v2 keeps this.
- **Self-hosted runner on a public repo**: flagged as a risk in v1; removed
  entirely in v2 by switching to pull-based deploys.
