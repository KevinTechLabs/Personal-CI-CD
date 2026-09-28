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
- `/ready`: *readiness*. The database is reachable **and** its Alembic revision
  equals the head this build expects. That catches "new code, old schema".
- `/version`: which commit is running. The agent requires this to match the
  release it just deployed, which proves the *new* containers are the ones
  answering (v1's README verified this by hand).

## 2. The pipeline

`.github/workflows/pipeline.yml`, least-privilege permissions per job:

1. **quality**: lockfile freshness, Ruff, Bandit, pip-audit against the
   hashed lock, ShellCheck, Compose validation, the GitOps agent scenario
   tests, TruffleHog over full history.
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
        ─▶ pull images
        ─▶ run migrations while the OLD release keeps serving
             fail ─▶ stop; nothing was replaced
        ─▶ replace api + worker
        ─▶ wait for /ready and /version == APP_VERSION
             fail ─▶ roll back
        ─▶ soak: synthetic traffic + readiness + Prometheus
           env:http_error_ratio:rate2m ≤ MAX_ERROR_RATIO
             fail ─▶ roll back
        ─▶ record as applied; staging adds digest to verified list
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

## 5. Observability

`deploy/observability/` runs Prometheus and Grafana on a shared Docker
network called `observability`. Each environment's `api` and `worker` join
it with the aliases `api-<env>` / `worker-<env>`, so one Prometheus scrapes
both environments with an `env` label.

- Recording rules precompute the error ratio (the rollback SLO) and p95 latency.
- Alerts: `HighErrorRatio`, `TargetDown`, `QueueBacklog`.
- The Grafana dashboard shows the deployed version per environment and
  annotates every version change.
- HTTP metrics use route templates (`/api/tasks/{task_id}`), not raw paths,
  to keep label cardinality bounded. Probe and scrape endpoints are excluded
  so they don't dilute the SLO.

## 6. Security model and trade-offs

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
