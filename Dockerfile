# syntax=docker/dockerfile:1

# One image, three roles: the API (default), the worker and the migration job
# all run from the same artifact, so exactly one digest is scanned, signed
# and promoted per commit.

# Base images are pinned by digest (tag kept for readability); Dependabot
# bumps both together, so a rebuild can never silently pick up a different image.
FROM ghcr.io/astral-sh/uv:0.12.19@sha256:04d046b13e60d6bcec73cbc5e1cad25d680dea90c8573340950a0ac2d1aef424 AS uv

# ---- build stage: resolve dependencies from the lockfile ---------------------
FROM python:3.14-alpine@sha256:f6a589d43c42b9e7f7dc67a12d37132491f362859a5d750607710cc56da3bc72 AS build

COPY --from=uv /uv /bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /src
COPY pyproject.toml uv.lock ./
# --locked: fail if uv.lock is out of date instead of silently re-resolving.
RUN uv sync --locked --no-dev --no-install-project

# ---- runtime stage -----------------------------------------------------------
FROM python:3.14-alpine@sha256:f6a589d43c42b9e7f7dc67a12d37132491f362859a5d750607710cc56da3bc72 AS runtime

ARG APP_VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="personal-ci-cd" \
      org.opencontainers.image.description="FastAPI + Postgres + worker CI/CD demo" \
      org.opencontainers.image.source="https://github.com/KevinTechLabs/Personal-CI-CD" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}"

# Keep OS packages current and strip build tooling from the runtime image.
# (v1 lesson: Trivy flagged pip/setuptools metadata that the app never uses.)
RUN apk upgrade --no-cache \
    && { python -m pip uninstall -y pip setuptools 2>/dev/null || true; } \
    && rm -rf /usr/local/lib/python3*/ensurepip \
    && addgroup -S -g 10001 app \
    && adduser -S -D -H -u 10001 -G app app

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION}

WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY alembic.ini ./
COPY migrations ./migrations
COPY app ./app

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=4s --start-period=10s --retries=3 \
    CMD ["python", "-m", "app.healthcheck", "http://127.0.0.1:8000/health"]

CMD ["uvicorn", "app.api:app", "--host", "0.0.0.0", "--port", "8000", "--no-server-header"]
