# Personal CI/CD Platform: v2

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
                       ├─ quality   ruff · bandit · pip-audit · trufflehog · shellcheck · agent tests
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
                                       ├─ replace api/worker ─▶ wait for /ready + exact version
                                       ├─ soak: synthetic traffic + Prometheus error-ratio SLO
                                       └─ breach? ─▶ roll back, remember bad revision
                                                   │
                         staging :8081  ◀──────────┴──────────▶  production :8080
                         api · worker · postgres                  api · worker · postgres
                                        ╲                        ╱
                                         Prometheus + Grafana :3000
```

## What's in the box

| Area | What it does |
|---|---|
| **Application** | FastAPI API, background worker, Postgres. Tasks are queued in Postgres and claimed with `FOR UPDATE SKIP LOCKED`: safe with many workers, and crash-safe with no stuck jobs. Alembic migrations. `/health` (liveness), `/ready` (DB reachable **and** schema at the expected revision), `/version`, `/metrics`. |
| **Tests** | Unit tests plus integration tests against a real Postgres service container, including concurrent-worker and migration round-trip tests. 80% coverage gate. DB tests can't silently skip in CI. |
| **Supply chain** | Dependencies locked with hashes (`uv.lock`); every GitHub Action pinned by commit SHA; Dependabot for Python, images, Compose and Actions; CodeQL (Python + workflow injection); dependency review on PRs; Bandit; pip-audit; TruffleHog; Trivy gate + SARIF; SPDX SBOM; keyless cosign signature + SBOM attestation; SLSA build provenance. |
| **Image** | Multi-stage Alpine build, non-root (uid 10001), no pip/setuptools at runtime, read-only root filesystem, all capabilities dropped, OCI labels with commit SHA. One image, three roles (api, worker, migrate): one digest to scan, sign and promote. |
| **Promotion** | Staging updates automatically on every green `main`. Production waits for a required reviewer, then receives *the exact digest and compose file staging is running*. The script refuses if staging has moved on. |
| **GitOps** | Desired state lives in Git (`environments` branch). A small agent on AI-LAB reconciles it: no inbound access, no GitHub credentials on the host, no self-hosted runner. Rolling back = `git revert`. |
| **Safety** | Signature verification before deploy; production only accepts digests that passed staging on the same host; migrations before cutover; readiness + version check; SLO soak with automatic rollback; bad revisions are not retried; drift self-healing. |
| **Observability** | Prometheus (recording rules + alerts) and a provisioned Grafana dashboard: request rate, error ratio vs. rollback SLO, p95 latency, queue depth, deployed version per environment with deploy annotations. |

## Repository layout

```text
app/                    FastAPI app, worker, models, metrics
migrations/             Alembic migrations (must be backward compatible)
tests/                  pytest suite; tests/agent/ = GitOps agent scenario tests
Dockerfile              one image for api / worker / migrate
pyproject.toml, uv.lock dependencies (locked, hashed)
deploy/compose/         per-environment Compose stack + settings (promoted)
deploy/agent/           GitOps agent, systemd units, installer
deploy/observability/   Prometheus + Grafana stack
scripts/promote.sh      commits a release to the environments branch
scripts/smoke-test.sh   end-to-end check used by CI and by hand
.github/                pipeline, CodeQL, dependency review, Dependabot
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
5. Set it back to `0` and push to recover.

Follow along with `journalctl -fu gitops-agent` and the Grafana dashboard.

## Getting started

See **[docs/OPERATIONS.md](docs/OPERATIONS.md)** for the one-time GitHub
settings, AI-LAB setup, and migrating from v1. The design rationale is in
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## v1

v1 (Flask, push deploy through a self-hosted runner) is preserved in Git
history; its lessons (immutable SHA tags, stripping pip/setuptools to clear
Trivy findings, the public-repo self-hosted-runner risk) shaped v2.
