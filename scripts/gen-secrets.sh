#!/usr/bin/env bash
# Generate the `scripulya-secrets` Secret in-cluster from your local .env.
# Only true SECRET keys are placed in the Secret (non-secret tunables live in the
# scripulya-config ConfigMap). Idempotent (kubectl apply).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="${ENV_FILE:-.env}"
NAMESPACE="${NAMESPACE:-scripulya}"

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ $ENV_FILE not found. Run: cp .env.example .env  (then fill secrets)" >&2
  exit 1
fi

command -v kubectl >/dev/null || { echo "❌ kubectl not found" >&2; exit 1; }

# Load .env values into this shell (KEY=VALUE lines, comments/blanks ignored).
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# Whitelist: only these keys go into the Secret.
SECRET_KEYS=(JWT_SECRET_KEY MINIO_ROOT_USER MINIO_ROOT_PASSWORD OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY ZAI_API_KEY DEEPSEEK_API_KEY)

args=()
for k in "${SECRET_KEYS[@]}"; do
  val="${!k-}"          # indirect expansion; empty if unset
  args+=(--from-literal="$k=$val")
done

kubectl create secret generic scripulya-secrets -n "$NAMESPACE" \
  --dry-run=client -o yaml "${args[@]}" | kubectl apply -f -

echo "✅ Secret scripulya-secrets synced in namespace $NAMESPACE from $ENV_FILE"