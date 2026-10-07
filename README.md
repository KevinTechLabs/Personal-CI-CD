# Personal CI/CD Platform: v2

[![Pipeline](https://github.com/KevinTechLabs/Personal-CI-CD/actions/workflows/pipeline.yml/badge.svg)](https://github.com/KevinTechLabs/Personal-CI-CD/actions/workflows/pipeline.yml)
[![Security scan](https://github.com/KevinTechLabs/Personal-CI-CD/actions/workflows/security-scan.yml/badge.svg)](https://github.com/KevinTechLabs/Personal-CI-CD/actions/workflows/security-scan.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/KevinTechLabs/Personal-CI-CD/badge)](https://scorecard.dev/viewer/?uri=github.com/KevinTechLabs/Personal-CI-CD)

An end-to-end delivery pipeline for a small multi-service application,
built to demonstrate how software gets from a `git push` to a running,
observable, automatically-rolled-back service in a homelab.

**v2** replaces v1's single Flask container and push-based self-hosted runner
with a FastAPI + Postgres + worker application, a supply-chain-secured build,
staging → production promotion with a manual approval gate, pull-based
GitOps deployment, and SLO-driven automatic rollback.

```text
 REACTOR (dev)                    GitHub                                   AI-LAB (homelab)
 ─────────────                    ──────                                   ────────────────
 git push ──▶ main ──▶ Pipeline
                       ├─ quality   ruff · bandit · pip-audit · trufflehog · shellcheck · actionlint
                       │            agent scenario tests · promtool alert-rule unit tests
                       ├─ test      pytest against real Postgres (coverage gate 80%)
                       ├─ build     one image ─▶ Trivy gate ─▶ full-stack smoke test
                       ├─ publish   push exact scanned bytes ─▶ SBOM ─▶ cosign sign + attest ─▶ SLSA provenance
                       ├─ promote-staging     commit digest ─▶ `environments` branch
                       └─ promote-production  ⏸ manual approval ─▶ commit same digest
                                                   │
                                                   │   (AI-LAB pulls; nothing pushes to it)
                                                   ▼
                                       gitops-agent (systemd timer, every 60s)
                                       ├─ production digest must have passed staging here
                                       ├─ cosign verify signature + SBOM attestation
                                       ├─ migrations first, old release keeps serving
                                       ├─ disk preflight, verified DB backup, then migrations
                                       │    (old release keeps serving)
                                       ├─ replace api/worker ─▶ wait for /ready + API version
                                       │    + a heartbeat from a worker running the NEW version
                                       ├─ soak: synthetic traffic, worker heartbeat, error-ratio SLO
                                       └─ breach? ─▶ roll back, remember bad revision
                                                   │
                         staging :8081  ◀──────────┴──────────▶  production :8080
                         api · worker · postgres                  api · worker · postgres
                                        ╲                        ╱
                     Prometheus · Alertmanager · blackbox probes · node-exporter · Grafana :3000
                                                   │
        Sentinel (SOC dashboard): one alert inbox + Discord + dead man's switch ◀─┘
        healthchecks.io (off-box): Discord alert if kevin-ai itself goes silent

 Scheduled (Mon/Thu): re-scan the DEPLOYED digests + lockfile ─▶ GitHub issue opens/closes itself
```

## What's in the box

| Area | What it does |
|---|---|
| **Application** | FastAPI API, background worker, Postgres. Tasks are queued in Postgres and claimed with `FOR UPDATE SKIP LOCKED`: safe with many workers, and crash-safe with no stuck jobs. Alembic migrations. `/health` (liveness), `/ready` (per-dependency report, below), `/version`, `/metrics`. |
| **Health checks** | `/ready` reports each dependency as ok / degraded / fail: **database** (reachable, latency budget), **schema** (at the expected Alembic revision), **worker** (live heartbeats and which versions they run), **queue** (age of the oldest waiting task). Only database/schema failures return 503; a stuck worker shows as degraded without taking the API out of service. Docker healthchecks restart dead processes; blackbox probes check every environment from the outside. |
| **Dependency checks** | Build time: pip-audit, dependency review, Trivy, lockfile freshness. Twice weekly: re-scan the images *actually deployed*, re-verify their signatures, audit the lockfile and report outdated packages; one GitHub issue opens on failure (including a scan that stalls past its 20-minute limit) and closes itself when fixed. Continuously: probes of GHCR, GitHub and Sigstore, the external services every deploy depends on. OpenSSF Scorecard grades the repo's supply-chain posture. |
| **Tests** | Unit tests plus integration tests against a real Postgres service container, including concurrent-worker and migration round-trip tests. 80% coverage gate. DB tests can't silently skip in CI. |
| **Supply chain** | Dependencies locked with hashes (`uv.lock`); every GitHub Action pinned by commit SHA; Dependabot for Python, images, Compose and Actions; CodeQL (Python + workflow injection); dependency review on PRs; Bandit; pip-audit; TruffleHog; Trivy gate + SARIF; SPDX SBOM; keyless cosign signature + SBOM attestation; SLSA build provenance. |
| **Image** | Multi-stage Alpine build, non-root (uid 10001), no pip/setuptools at runtime, read-only root filesystem, all capabilities dropped, OCI labels with commit SHA. One image, three roles (api, worker, migrate): one digest to scan, sign and promote. |
| **Promotion** | Staging updates automatically on every green `main`. Production waits for a required reviewer, then receives *the exact digest and compose file staging is running*. The script refuses if staging has moved on. |
| **GitOps** | Desired state lives in Git (`environments` branch). A small agent on AI-LAB reconciles it: no inbound access, no GitHub credentials on the host, no self-hosted runner. Rolling back = `git revert`. |
| **Safety** | Signature verification before deploy; production only accepts digests that passed staging on the same host; disk-space preflight; migrations before cutover; the new release must answer with its version **and** have a live worker on that version; SLO + heartbeat soak with automatic rollback; bad revisions are not retried; drift self-healing; old images pruned. |
| **Alerting** | 20 alerts (plus SLO and DORA recording rules), every one covered by a `promtool` unit test in CI. Alerts and deploy events go to **Sentinel**, the lab's SOC dashboard: one inbox with acknowledge / escalate / close, ATT&CK mapping, auto-close on resolve, and Discord for high/critical. Sentinel also acts as the dead man's switch: if AI-LAB's monitoring stops sending its heartbeat, Sentinel raises it. Uses an ingest-only key that can't touch the firewall. **Whole-machine outages** are covered too: the agent pings healthchecks.io after every run, which posts to Discord if kevin-ai goes silent (it works when the house's power or internet is out), and when kevin-ai is back the agent reports the outage to Sentinel with exact times, as a reboot (high) or a stopped agent (medium). |
| **Backups** | A verified `pg_dump` of production before **every migration** (no backup, no migration) and daily, 14 kept. Each dump must pass `pg_restore --list` before it counts. `deploy/agent/restore-db.sh` restores in one transaction after taking a safety backup. Alerts if backups go stale or fail. |
| **DORA metrics** | Deployment frequency, lead time for changes (commit → running), change failure rate and time to restore, measured by the GitOps agent and shown on Grafana with DORA performance-tier colors. |
| **Observability** | Two provisioned Grafana dashboards. *Service overview*: request rate, error ratio vs. rollback SLO, p95 latency, queue, deployed version with deploy annotations. *Platform health*: probe status, every dependency check, external dependencies, GitOps agent state/rollbacks, host disk/memory/CPU/clock. |

## Repository layout

```text
app/                    FastAPI app, worker, models, metrics
migrations/             Alembic migrations (must be backward compatible)
tests/                  pytest suite; tests/agent/ = GitOps agent scenarios;
                        tests/monitoring/ = alert-rule unit tests (promtool)
Dockerfile              one image for api / worker / migrate
pyproject.toml, uv.lock dependencies (locked, hashed)
deploy/compose/         per-environment Compose stack + settings (promoted)
deploy/agent/           GitOps agent, systemd units, installer, restore-db.sh
deploy/observability/   Prometheus, Alertmanager, blackbox, node-exporter, Grafana
scripts/promote.sh      commits a release to the environments branch
scripts/smoke-test.sh   end-to-end check used by CI and by hand
.github/                pipeline, scheduled security scan, CodeQL, Scorecard,
                        dependency review, Dependabot
docs/ARCHITECTURE.md    how it works and why
docs/OPERATIONS.md      setup, day-2 operations, v1 → v2 migration
```

## Try it locally

```bash
uv lock                      # first time only: generates uv.lock
make dev                     # builds and starts api + worker + postgres on :8081
make smoke                   # end-to-end check
make test                    # pytest against the dev database
make test-agent              # GitOps agent rollback/gating scenarios
make dev-down
```

## Demo: watch an automatic rollback

1. In `deploy/compose/staging.env`, set `CHAOS_ERROR_RATE=0.5` and push to `main`.
2. The pipeline goes green and promotes to staging (health probes are exempt
   from the fault injection, so the release *looks* healthy).
3. During the soak, the agent sees the error ratio jump past 5% in
   Prometheus and rolls staging back. It won't retry that revision.
4. Production's approval job would be pointless: the agent refuses any
   digest that didn't pass staging.
5. Sentinel gets a high "staging rolled back" alert (and Discord a
   message), and Grafana's Platform health dashboard shows the rollback.
6. Set it back to `0` and push to recover.

Follow along with `journalctl -fu gitops-agent` and the Grafana dashboards.

## See the dependency checks

```bash
curl -s localhost:8081/ready | python3 -m json.tool
```
```json
{
  "status": "ready",
  "version": "65cda30…",
  "checks": {
    "database": { "status": "ok", "latency_ms": 1.4 },
    "schema":   { "status": "ok", "current": "0002", "expected": "0002" },
    "worker":   { "status": "ok", "active_workers": 1, "versions": ["65cda30…"], "last_heartbeat_seconds": 2.1 },
    "queue":    { "status": "ok", "pending": 0, "oldest_pending_seconds": 0.0 }
  }
}
```
Stop the worker (`docker compose -p cicd-staging stop worker`) and `worker`
turns `degraded` immediately, the API keeps serving, and a few minutes later
`WorkerHeartbeatStale (staging)` appears in Sentinel and Discord.

## Getting started

See **[docs/OPERATIONS.md](docs/OPERATIONS.md)** for the one-time GitHub
settings, AI-LAB setup, and migrating from v1. The design rationale is in
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## v1

v1 (Flask, push deploy through a self-hosted runner) is preserved in Git
history; its lessons (immutable SHA tags, stripping pip/setuptools to clear
Trivy findings, the public-repo self-hosted-runner risk) shaped v2.
