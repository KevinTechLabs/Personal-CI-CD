# Architecture

This document explains how v2 works and, more importantly, why each piece
is shaped the way it is.

## 1. The application

Three processes, one image:

| Role | Command | Purpose |
|---|---|---|
| `api` | `uvicorn app.api:app` | HTTP API on :8000, metrics at `/metrics` |
| `worker` | `python -m app.worker` | drains the task queue; metrics on :9100 |
| `migrate` | `alembic upgrade head` | one-shot schema migration |

Shipping all three from one image means there is exactly one digest per
commit to scan, sign, attest and promote. There is no way for the API and
worker to be on mismatched versions.

**The queue is Postgres.** A worker claims, processes and completes a task
inside one transaction using `SELECT … FOR UPDATE SKIP LOCKED`. Concurrent
workers skip each other's rows, and if a worker dies mid-task its transaction
rolls back and the task is simply pending again. No Redis, no "stuck in
processing" cleanup job. `tests/test_worker.py` runs four workers against 20
tasks and asserts each is processed exactly once.

**Probes mean different things.**

- `/health`: *liveness*. The process is up. It never touches the database,
  so a DB outage doesn't make Docker restart healthy API containers in a loop.
- `/ready`: *readiness*, with a per-dependency report (`app/health.py`):

  | check | ok when | on failure |
  |---|---|---|
  | `database` | `SELECT 1` answers within 250ms | **fail → 503** (slow → degraded) |
  | `schema` | Alembic revision = the head this build expects | **fail → 503** |
  | `worker` | a heartbeat younger than 30s; lists live worker versions | degraded, still 200 |
  | `queue` | oldest pending task younger than 5 min | degraded, still 200 |

  Only *critical* checks take an instance out of service. A stuck worker
  doesn't stop the API accepting tasks, so it reports `degraded` instead,
  which is visible to people (Grafana, alerts) and to the GitOps agent.
- `/version`: which commit is running.

**Worker heartbeats.** The worker can't be probed over HTTP by the API, so
every 5s it upserts a row in `worker_heartbeats` (ID, version, last seen,
tasks processed) and deletes it on clean shutdown. `/ready` reads those rows.
That is what lets the agent require *a worker running the new version* before
it declares a deploy successful: a release whose worker crash-loops is
rolled back even though its API looks perfect. Rows left by killed workers
age out of the check after 30s and are pruned after 24h.

## 2. The pipeline

`.github/workflows/pipeline.yml`, least-privilege permissions per job:

1. **quality**: lockfile freshness, Ruff, Bandit, pip-audit against the
   hashed lock, ShellCheck, actionlint, Compose validation, the GitOps agent
   scenario tests, Prometheus/Alertmanager/blackbox config checks and
   `promtool` alert-rule unit tests, TruffleHog over full history.
2. **test**: pytest against a Postgres 18 service container, 80% coverage
   gate. `REQUIRE_DATABASE=1` turns a missing DB into an error, so integration
   tests can never be skipped silently.
3. **build**: builds once, Trivy SARIF → code scanning, Trivy gate (fixable
   CRITICAL/HIGH fails), then brings up the full Compose stack and runs
   `scripts/smoke-test.sh`, which pushes a task through API → Postgres → worker.
4. **publish** (main only): pushes **the exact image bytes that were scanned
   and smoke tested** (handed over as an artifact, never rebuilt), asks the
   registry for the digest, generates an SPDX SBOM, signs keylessly with
   cosign via GitHub OIDC, attaches the SBOM as a signed attestation, and
   records SLSA build provenance.
5. **promote-staging**: commits the digest to the `environments` branch.
6. **promote-production**: waits for a required reviewer (GitHub
   Environment protection), then copies *staging's* `compose.yaml` and
   `release.env` to production. It refuses if staging has moved on to a
   newer version, so you can only approve what staging is actually running.

Only jobs 4–6 hold write permissions, and only on `main`. Pull requests run
1–3 with read-only tokens.

**Why actions are pinned by SHA.** In March 2026 attackers force-pushed 76 of
77 `aquasecurity/trivy-action` tags to credential-stealing code. v1 happened
to use 0.35.0, the one tag that was protected. Tags are mutable; commit SHAs
aren't. Dependabot keeps the SHAs current.

## 3. Pull-based GitOps

v1 deployed by having GitHub push work to a self-hosted runner on AI-LAB.
For a public repository that's a real risk (a workflow change could execute
on the homelab), and the host held a live connection to GitHub waiting for
jobs.

v2 inverts it. CI's only deploy action is a Git commit to the `environments`
branch:

```text
environments branch
├── staging/
│   ├── compose.yaml   the stack definition staging should run
│   ├── config.env     non-secret settings (port, env name)
│   └── release.env    APP_IMAGE=…@sha256:…, APP_VERSION=<commit>
└── production/        same shape
```

`deploy/agent/gitops-agent.sh` runs on AI-LAB every minute, fetches that
branch anonymously (the repo is public), and reconciles. AI-LAB has **no
inbound exposure, no GitHub credentials, and no runner**. Because the
compose file is promoted alongside the digest, infrastructure changes
(e.g. a new service or resource limit) go through the same staging →
approval → production path as code.

This is the same model Argo CD uses on Kubernetes: Git is the source of
truth, and an in-cluster agent pulls. Rollback is `git revert`.

### Reconcile loop (per environment, staging first)

```text
fetch environments ─▶ tree hash changed?
   no  ─▶ drift check: api/worker/db running? if not, restore applied release
   yes ─▶ known-bad revision? ─▶ skip until a new commit or revert
        ─▶ production: digest must be in staging's verified list on this host
        ─▶ cosign verify signature + SBOM attestation (identity = this repo's
           pipeline.yml on refs/heads/main)
        ─▶ disk preflight (MIN_FREE_DISK_MB); retried later, not marked bad
        ─▶ pull images
        ─▶ production: verified pg_dump of the live DB (no backup, no migration)
        ─▶ run migrations while the OLD release keeps serving
             fail ─▶ stop; nothing was replaced
        ─▶ replace api + worker
        ─▶ wait for /ready = 200, /version == APP_VERSION, and APP_VERSION
           in /ready's live worker versions
             fail ─▶ roll back (the reason names the failing check)
        ─▶ soak: synthetic traffic + readiness + new worker still alive +
           Prometheus env:http_error_ratio:rate2m ≤ MAX_ERROR_RATIO
             fail ─▶ roll back
        ─▶ record as applied; staging adds digest to verified list;
           prune this app's images unused for 7 days
        ─▶ every run: write agent metrics for node-exporter
```

A rolled-back revision is recorded in `failed.rev` so the agent doesn't
flap between good and bad releases every minute. Promoting a new commit or
reverting clears it.

### Why production checks staging *on the host*

The approval gate is a human judgement; the host-side check is a mechanical
guarantee. Even if someone approves a production job for a release that
failed its staging soak, the agent will not deploy it.

## 4. Database migrations: expand / contract

Migrations run *before* the new containers start, while the previous release
is still serving. So every migration must work with both the old and the new
code:

- **Expand** (this release): add nullable columns, new tables, new indexes.
- **Contract** (a later release, once nothing uses the old shape): drop or
  rename.

This is also why automatic rollback doesn't downgrade the schema: the
previous release is, by construction, compatible with the new schema.
`tests/test_migrations.py` enforces a single Alembic head and a clean
downgrade/upgrade round trip.

## 5. Observability and alerting

`deploy/observability/` runs Prometheus and Grafana on a shared Docker
network called `observability`. Each environment's `api` and `worker` join
it with the aliases `api-<env>` / `worker-<env>`, so one Prometheus scrapes
both environments with an `env` label.

Watching from four angles:

| Layer | Source | Example alerts |
|---|---|---|
| Is it serving? | blackbox probes `/ready` like a user | `EndpointDown`, `SlowReadinessProbe` |
| Are its dependencies OK? | `readiness_check_*` gauges from `/ready` | `ReadinessDegraded`, `WorkerHeartbeatStale`, `QueueBacklog` |
| Can we still deploy? | blackbox probes GHCR, GitHub, Sigstore; agent metrics | `DeployDependencyUnreachable`, `GitOpsAgentStale`, `GitOpsEnvironmentUnhealthy`, `GitOpsRolledBack` |
| Is the host OK? | node-exporter | `HostDiskAlmostFull`, `HostDiskWillFillSoon`, `HostMemoryPressure`, `HostClockSkew` |

`HostClockSkew` exists because cosign checks certificate validity windows: a
drifting clock makes perfectly valid images fail verification.

**The GitOps agent reports on itself.** Each run writes
`/var/lib/gitops-agent/metrics/gitops.prom` (last run time, state per
environment, deploys, rollbacks, drift heals), which node-exporter's textfile
collector serves. If the timer dies, `GitOpsAgentStale` fires.

**One inbox: Sentinel.** Alertmanager delivers every alert, and its
resolution, to [Sentinel](https://github.com/KevinTechLabs/Homelab-Soc-Dashboard),
the lab's SOC dashboard, through its ingest API using an ingest-only key. The
GitOps agent sends deploy events there too. Operational and security alerts
share one triage flow (acknowledge / escalate / close), one ATT&CK view and
one Discord channel:

| Prometheus `severity` | Sentinel | Discord |
|---|---|---|
| `page` | high | yes |
| `warn` | medium | no (inbox) |

Rules carry `mitre_technique` / `mitre_tactic` labels using the techniques
Sentinel's own detections use for the same symptoms (T1489 Service Stop for
a down service, T1499 Endpoint DoS for exhaustion, T1562.006 Indicator
Blocking for monitoring going dark). A refused unsigned image is reported as
T1195.002 Compromise Software Supply Chain, critical. Inhibition rules keep
one outage to one alert (e.g. `EndpointDown` suppresses that environment's
symptom alerts).

**Who watches the watcher?** The `Watchdog` alert is always firing and
reaches Sentinel every minute as a heartbeat. If it stops (Docker or
Alertmanager dead) Sentinel raises *Monitoring on ai-lab stopped reporting*
after 5 minutes; if Prometheus dies, Alertmanager sends the Watchdog as
*resolved* once it expires (~4 minutes) and Sentinel raises it immediately.
It closes itself when heartbeats resume. This was drilled end-to-end against
real Prometheus and Alertmanager binaries.

Sentinel runs on the same machine (kevin-ai), so a dead *machine* takes
Sentinel down too. That last layer belongs off-box: NexusLab's
machine-offline alert and an Uptime Kuma HTTP check of Sentinel's
`/api/health`, both running on other hardware and posting to the same
Discord. Each failure has a reporting path that doesn't share its fate. Every alert has a `promtool` unit test in
`tests/monitoring/rules_test.yml`, so rule changes can't silently break
alerting.

Other details:

- Recording rules precompute the error ratio (the rollback SLO) and p95 latency.
- Two Grafana dashboards: *Service overview* (traffic, errors, latency,
  queue, deploy annotations) and *Platform health* (probes, dependency
  checks, external deps, agent, host).
- HTTP metrics use route templates (`/api/tasks/{task_id}`), not raw paths,
  to keep label cardinality bounded. Probe and scrape endpoints are excluded
  so they don't dilute the SLO.

## 6. Backups and delivery metrics

**Backups are part of the deploy.** For environments in
`BACKUP_ENVIRONMENTS` (production by default) the agent runs `pg_dump
--format=custom` inside the database container right before migrations, and
again whenever the newest dump is older than a day. A dump only counts once
`pg_restore --list` can read it; otherwise it's deleted, the failure is
counted, and a pre-migration failure blocks the deploy (it retries next run).
Dumps are `0600` in a `0700` directory, the newest 14 are kept, and
`restore-db.sh` restores one in a single transaction after taking a safety
backup. The backup/verify/restore commands were tested against a real
PostgreSQL: delete all rows and drop a table, restore, and everything is
back at the same schema revision.

**DORA metrics come from the agent, not from CI.** CI knows when it
*promoted* something; only the agent knows when it actually *ran*
successfully. `promote.sh` records the commit time in `release.env`; on each
successful deploy the agent adds commit→running time to a running sum
(exported as a Prometheus summary). A rollback opens an incident and the
next successful deploy closes it, which gives time to restore. Prometheus
turns these into the four DORA metrics (`prometheus/dora.yml`, unit tested
separately because of its 30-day windows).

## 7. Continuous dependency checking

Build-time scans only describe the day an image was built. The
`security-scan` workflow (Mon/Thu) reads the digests actually deployed from
the `environments` branch and, for each one, re-verifies its signature and
runs Trivy, uploading findings to code scanning (`deployed-staging`,
`deployed-production`). It also pip-audits the lockfile and writes an
outdated-dependency report to the run summary. A single GitHub issue labeled
`security-scan` opens on failure, gets a comment on each repeat, and closes
itself when a run passes. Fixing it is the normal flow: Dependabot (or you)
bumps the dependency → pipeline → staging → approve.

OpenSSF Scorecard grades the repository's own supply-chain hygiene weekly.

## 8. Security model and trade-offs

- **The docker group is root-equivalent.** The agent runs as a dedicated
  `gitops` user in that group under a hardened systemd unit. That's the
  honest limit of Compose on a single host; rootless Docker is the next step.
- **Secrets** (Postgres passwords) live only in `/etc/gitops-agent/secrets/`
  on AI-LAB, readable by root and the `gitops` group. They never enter Git or CI.
- **Base images are pinned by tag, not digest.** Dependabot will propose
  updates; pinning `python:3.14-alpine` to a digest is a worthwhile hardening
  follow-up.
- **Single host.** Staging and production share AI-LAB, so staging proves
  the release and the procedure, not isolation. Moving production to a
  second host needs only a second agent with `ENVIRONMENTS=production` and
  a way to share the verified-digest list (or relax that check there).
