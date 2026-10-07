# 📝 Changelog

What changed, and why. Newest first. Deploys are `main` merges; each one
flows through staging and, after approval, production on kevin-ai.

## 🛡️ 2026-10-06: OpenSSF Scorecard improvements

Scorecard was 5.7/10. Added an MIT `LICENSE` and a `SECURITY.md` (private
vulnerability reporting), pinned the Dockerfile's base images by digest
(Dependabot keeps tag and digest current), and protected `main` with a
ruleset (PRs and passing checks required, no force-push or deletion).
Not pursued: Code-Review (needs a second reviewer), Maintained (repo under
90 days old), Contributors, Fuzzing, CII badge.

## ✅ 2026-10-06: Outage alerting verified

- Tested end to end by stopping the agent's timer: healthchecks.io posted
  *kevin-ai is DOWN* to `#healthchecks-alerts` after ~11 minutes and *UP*
  on restart; Sentinel raised *GitOps agent on ai-lab didn't run* and
  `GitOpsAgentStale` resolved by itself.
- Found during the test: healthchecks.io's default check period is 1 day,
  which delays alerts by 24 h. The check now uses 1 minute; documented in
  OPERATIONS.md.
- Scheduled OpenSSF Scorecard run #8 failed at the results upload and passed
  on re-run (GitHub-side). Noted: GitHub moves `ubuntu-latest` to Ubuntu 26
  on 2026-10-19; nothing in the workflows depends on the 24.04 image, so no
  change made. If a run breaks around then, pin `runs-on: ubuntu-24.04`.

## 🚀 2026-10-05: Live on kevin-ai

**#7 Report kevin-ai outages to Sentinel** (`2fb049e`). Each agent run
records when it last ran. A gap over 5 minutes is raised in Sentinel once it
is reachable again: high *ai-lab was offline for Nm* (T1529) when the kernel
boot time shows a reboot, medium *agent didn't run* (T1489) otherwise. The
report is kept until Sentinel accepts it, since Sentinel may still be
starting after a boot. 9 new agent scenario checks (74 total).

**#6 Off-box heartbeat** (`8473759`). Sentinel and NexusLab both run on
kevin-ai, so a dead machine couldn't report itself. The agent now pings
healthchecks.io after every run (`HEARTBEAT_URL`); liveness only, so a
failed deploy still pings. A hung agent holds the lock and goes silent; an
unreachable heartbeat service never fails a run. 5 new checks.

**#5 Security scan hardening** (`e5f9e48`). The first scheduled scan had one
image scan hang for 15 minutes and get cancelled, and a cancelled job didn't
open the tracking issue. Image scans now have a 20-minute limit, pull the
Trivy DB from mirrors first, and "cancelled" counts as a failure.

**#2, #3 Dependabot** (`3128757`, `85a72b2`). Grafana 13.2.2 → 13.2.3
(observability stack, applied on kevin-ai with `docker compose up -d
grafana`); `anchore/sbom-action` 0.24.2 → 0.24.3.

**#4 install.sh executable** (`fbfe0df`). It was committed as 100644, so
`sudo deploy/agent/install.sh` failed with *Permission denied*.

**First production rollout.** Agent installed on kevin-ai, alerts connected
to Sentinel (ingest-only key), observability stack up, Grafana on :3000.
Every merge above went staging → soak → approval → backup → production
with no rollbacks; the approval gate held for each production deploy.

## 🏗️ 2026-10-04: v2 pipeline (#1)

Multi-service app (FastAPI + worker + Postgres), supply-chain-secured
pipeline (pinned actions, SBOM, cosign signatures and attestations, SLSA
provenance, Trivy gate), pull-based GitOps with staging → production
promotion, deep health checks, auto-rollback on SLO breach, pre-migration
backups, DORA metrics and alerting through Sentinel. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
