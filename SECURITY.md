# 🔒 Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems.

Report it privately through GitHub instead: **Security → Report a
vulnerability** on this repository. Include what you found, how to reproduce
it, and what an attacker could do with it. You'll get a reply within a few
days, and a fix or an explanation as soon as possible after that.

## Supported versions

Only the latest commit on `main` (what runs in production) is supported.

## What's already in place

- Every image is scanned (Trivy), signed (keyless cosign) and shipped with an
  SBOM attestation and SLSA provenance; the deploy agent refuses anything
  that isn't signed by this repository's pipeline on `main`.
- Dependencies are locked with hashes; every GitHub Action is pinned by
  commit SHA; Dependabot keeps them current.
- CodeQL, Bandit, pip-audit, dependency review and TruffleHog run on every
  change; the images actually deployed are re-scanned twice a week.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (section 8)
for the security model and its trade-offs.
