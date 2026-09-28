#!/usr/bin/env bash
# Promote a release into an environment by committing it to the
# `environments` branch. The GitOps agent on AI-LAB watches that branch and
# applies whatever is committed there; this script never talks to AI-LAB.
#
#   scripts/promote.sh staging     IMAGE_REF=<repo>@sha256:<digest> VERSION=<git sha>
#   scripts/promote.sh production  VERSION=<git sha>
#
# staging:     writes staging/{compose.yaml,config.env,release.env} from this
#              checkout plus the freshly built, signed image digest.
# production:  copies the exact compose.yaml + release.env that staging is
#              running, and refuses unless staging is at VERSION (so you can
#              only approve what staging actually has).
#
# Environment:
#   SRC_DIR      source checkout (default: repo root)
#   ENVS_DIR     where to check out the environments branch (default: ./.envs)
#   ENVS_BRANCH  default: environments
#   REMOTE       default: origin
#   RUN_URL      link recorded in release.env (default: GitHub run URL)

set -euo pipefail

target="${1:?usage: promote.sh <staging|production>}"
SRC_DIR="${SRC_DIR:-$(git rev-parse --show-toplevel)}"
ENVS_DIR="${ENVS_DIR:-$SRC_DIR/.envs}"
ENVS_BRANCH="${ENVS_BRANCH:-environments}"
REMOTE="${REMOTE:-origin}"
VERSION="${VERSION:?VERSION (git sha) is required}"
RUN_URL="${RUN_URL:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}}"

die() { echo "promote: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9a-f]{7,40}$ ]] || die "VERSION must be a git sha, got '$VERSION'"

git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "github-actions[bot]"
git config --global user.email >/dev/null 2>&1 || git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

# --- check out (or create) the environments branch as a worktree -------------
checkout_envs() {
  rm -rf "$ENVS_DIR"
  git -C "$SRC_DIR" worktree prune
  if git -C "$SRC_DIR" ls-remote --exit-code --heads "$REMOTE" "$ENVS_BRANCH" >/dev/null; then
    git -C "$SRC_DIR" fetch --quiet --depth 50 "$REMOTE" "$ENVS_BRANCH"
    git -C "$SRC_DIR" worktree add --quiet -B "$ENVS_BRANCH" "$ENVS_DIR" FETCH_HEAD
  else
    echo "promote: '$ENVS_BRANCH' branch does not exist yet; creating it"
    git -C "$SRC_DIR" worktree add --quiet --orphan -b "$ENVS_BRANCH" "$ENVS_DIR"
    cat > "$ENVS_DIR/README.md" <<'EOF'
# environments

Desired state for each environment, written only by the CI promotion jobs
and read by the GitOps agent on AI-LAB. Each directory holds the compose
file, settings and the signed image digest that should be running.

Roll back an environment with `git revert <promotion commit>` on this branch.
EOF
  fi
}

write_staging() {
  local image_ref="${IMAGE_REF:?IMAGE_REF (image@sha256:digest) is required for staging}"
  [[ "$image_ref" =~ ^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$ ]] \
    || die "IMAGE_REF must be a lowercase image reference pinned by digest, got '$image_ref'"
  local dir="$ENVS_DIR/staging"
  mkdir -p "$dir"
  cp "$SRC_DIR/deploy/compose/compose.yaml" "$dir/compose.yaml"
  cp "$SRC_DIR/deploy/compose/staging.env"  "$dir/config.env"
  cat > "$dir/release.env" <<EOF
# Written by scripts/promote.sh; do not edit by hand (revert the commit instead).
APP_IMAGE=$image_ref
APP_VERSION=$VERSION
PROMOTED_FROM=$RUN_URL
EOF
}

write_production() {
  local staging="$ENVS_DIR/staging" dir="$ENVS_DIR/production"
  [[ -f "$staging/release.env" ]] || die "staging has never been promoted"
  local staged
  staged="$(sed -n 's/^APP_VERSION=//p' "$staging/release.env")"
  [[ "$staged" == "$VERSION" ]] || die "staging is at '$staged', not '$VERSION'. \
Staging has moved on since this run; approve the production job of the newest run instead."
  mkdir -p "$dir"
  cp "$staging/compose.yaml" "$dir/compose.yaml"
  cp "$SRC_DIR/deploy/compose/production.env" "$dir/config.env"
  sed "s#^PROMOTED_FROM=.*#PROMOTED_FROM=$RUN_URL#" "$staging/release.env" > "$dir/release.env"
}

commit_and_push() {
  git -C "$ENVS_DIR" add -A
  if git -C "$ENVS_DIR" diff --cached --quiet; then
    echo "promote: $target already at $VERSION; nothing to do"
    return 0
  fi
  git -C "$ENVS_DIR" commit --quiet -m "$target: deploy ${VERSION:0:12}" -m "Run: $RUN_URL"
  # Staging and production promotions can race; they touch different
  # directories, so a rebase-and-retry always resolves cleanly.
  for attempt in 1 2 3 4 5; do
    if git -C "$ENVS_DIR" push --quiet "$REMOTE" "HEAD:refs/heads/$ENVS_BRANCH"; then
      echo "promote: $target -> ${VERSION:0:12} ($(git -C "$ENVS_DIR" rev-parse --short HEAD))"
      return 0
    fi
    echo "promote: push rejected (attempt $attempt), rebasing"
    git -C "$ENVS_DIR" pull --quiet --rebase "$REMOTE" "$ENVS_BRANCH"
  done
  die "could not push after 5 attempts"
}

checkout_envs
case "$target" in
  staging)    write_staging ;;
  production) write_production ;;
  *)          die "unknown environment '$target'" ;;
esac
commit_and_push
