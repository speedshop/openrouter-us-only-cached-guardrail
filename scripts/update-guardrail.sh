#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/.."

GUARDRAIL_NAME="${OPENROUTER_GUARDRAIL_NAME:-US Cached Models Only}"
API_BASE="https://openrouter.ai/api/v1"

if [[ -z "${OPENROUTER_PROVISIONING_KEY:-}" ]]; then
  echo "Error: OPENROUTER_PROVISIONING_KEY environment variable is required"
  exit 1
fi

validate_json() {
  local response="$1"

  if ! echo "$response" | jq -e '.' >/dev/null; then
    echo "Error: API returned invalid JSON"
    echo "$response"
    exit 1
  fi
}

# Read provider and model lists
PROVIDERS=$(jq -c '.' "${OUTPUT_DIR}/us-providers.json")
MODELS=$(jq -c '.' "${OUTPUT_DIR}/cached-models.json")

echo "Checking for existing guardrail named '${GUARDRAIL_NAME}'..."

# List existing guardrails
GUARDRAILS=$(curl -fsS "${API_BASE}/guardrails" \
  -H "Authorization: Bearer ${OPENROUTER_PROVISIONING_KEY}")

if ! echo "$GUARDRAILS" | jq -e '.data' >/dev/null; then
  echo "Error: Unexpected response from guardrails API"
  echo "$GUARDRAILS"
  exit 1
fi

# Find guardrail by name
GUARDRAIL_ID=$(echo "$GUARDRAILS" | jq -r --arg name "$GUARDRAIL_NAME" '
  .data // []
  | map(select(.name == $name))
  | first
  | .id // empty
')

# Build guardrail payload
PAYLOAD=$(jq -n \
  --arg name "$GUARDRAIL_NAME" \
  --argjson providers "$PROVIDERS" \
  --argjson models "$MODELS" \
  '{
    name: $name,
    allowed_providers: $providers,
    allowed_models: $models
  }')

if [[ -n "$GUARDRAIL_ID" ]]; then
  echo "Found existing guardrail (ID: ${GUARDRAIL_ID}). Updating..."

  RESPONSE=$(curl -fsS -X PATCH "${API_BASE}/guardrails/${GUARDRAIL_ID}" \
    -H "Authorization: Bearer ${OPENROUTER_PROVISIONING_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

  validate_json "$RESPONSE"
  echo "Update response:"
  echo "$RESPONSE" | jq '.'
else
  echo "No existing guardrail found. Creating new one..."

  RESPONSE=$(curl -fsS -X POST "${API_BASE}/guardrails" \
    -H "Authorization: Bearer ${OPENROUTER_PROVISIONING_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

  validate_json "$RESPONSE"
  echo "Create response:"
  echo "$RESPONSE" | jq '.'
fi

echo ""
echo "Guardrail '${GUARDRAIL_NAME}' has been updated successfully."
echo "View at: https://openrouter.ai/settings/guardrails"
