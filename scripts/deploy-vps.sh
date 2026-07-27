#!/usr/bin/env bash
# Idempotent production deploy entrypoint. Run ON the VPS (over SSH) from the
# deploy directory. The GitHub Actions "Deploy to VPS" workflow rsyncs the
# compose files + scripts/init.sql here and writes .env before calling this.
#
# Environment (passed in by the workflow):
#   DEPLOY_DIR  - absolute path to the deploy checkout on the VPS
#   GHCR_USER   - optional; GHCR username for `docker login` (private packages)
#   GHCR_TOKEN  - optional; GHCR PAT with read:packages
#
# What it does:
#   1. (optional) docker login ghcr.io  — only if private-package creds are set
#   2. docker compose ... pull          — fetch the GHCR images for this deploy
#   3. docker compose ... up -d         — recreate changed containers
#   4. wait for scripulya-ai health     — fail the deploy if it never turns green
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-$(pwd)}"
cd "$DEPLOY_DIR"
echo "==> Deploy dir: $DEPLOY_DIR"

# Load .env into this shell. `docker compose --env-file .env` only interpolates
# .env inside the compose file — it does NOT export vars into this shell, so
# without this the sanity checks (and the image-ref log lines below) can't see
# SCRIPULYA_*_IMAGE and fail with "... is not set in .env".
[ -f ./.env ] || { echo "!! .env not found in $DEPLOY_DIR (the deploy workflow must write it)" >&2; exit 1; }
set -a
. ./.env
set +a

# (1) GHCR auth only when both creds are present. Public packages pull
# anonymously and skip this entirely.
if [ -n "${GHCR_USER:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
  echo "==> docker login ghcr.io (private-package creds present)"
  printf '%s\n' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
else
  echo "==> No GHCR creds supplied — assuming public packages (anonymous pull)"
fi

# Sanity: the workflow must have written the image refs into .env.
: "${SCRIPULYA_AI_IMAGE:?SCRIPULYA_AI_IMAGE is not set in .env}"
: "${SCRIPULYA_AGENT_IMAGE:?SCRIPULYA_AGENT_IMAGE is not set in .env}"
[ -f ./init.sql ] || { echo "!! ./init.sql missing — postgres first-init would fail" >&2; exit 1; }

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env"

echo "==> Pulling images ($SCRIPULYA_AI_IMAGE, $SCRIPULYA_AGENT_IMAGE)"
$COMPOSE pull

echo "==> Bringing the stack up (--remove-orphans)"
$COMPOSE up -d --remove-orphans

# scripulya-ai gets container_name: scripulya-ai in docker-compose.prod.yml so we
# can inspect it by a stable name. It carries a Docker HEALTHCHECK on /health.
CONTAINER="scripulya-ai"
TIMEOUT="${HEALTH_TIMEOUT:-90}"
echo "==> Waiting up to ${TIMEOUT}s for ${CONTAINER} to become healthy"
deadline=$(( $(date +%s) + TIMEOUT ))
status="unknown"
while [ "$(date +%s)" -lt "$deadline" ]; do
  status="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo unknown)"
  [ "$status" = "healthy" ] && break
  sleep 3
done

echo "==> ${CONTAINER} health: ${status}"
echo "==> Container status:"
$COMPOSE ps

if [ "$status" != "healthy" ]; then
  echo "!! ${CONTAINER} did not become healthy; last 100 log lines:" >&2
  $COMPOSE logs --tail=100 scripulya-ai >&2 || true
  exit 1
fi

echo "==> Deploy complete: $SCRIPULYA_AI_IMAGE"
