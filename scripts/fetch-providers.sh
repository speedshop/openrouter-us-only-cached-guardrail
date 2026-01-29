#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/.."

echo "Fetching providers from OpenRouter API..."

# Fetch raw provider data
curl -s "https://openrouter.ai/api/v1/providers" | jq '.' > "${OUTPUT_DIR}/providers.json"

# US-based providers (from OpenRouter's provider regions)
# Excludes: openai, anthropic
# This list is based on known US-headquartered AI providers
US_PROVIDERS=(
  "together"
  "fireworks"
  "lepton"
  "octoai"
  "deepinfra"
  "lambda"
  "novita"
  "avian"
  "sf-compute"
  "infermatic"
  "featherless"
  "chutes"
  "nebius"
  "parasail"
  "nineteen"
)

echo "Filtering for US providers (excluding openai, anthropic)..."

# Build jq filter for US providers
FILTER=$(printf '"%s",' "${US_PROVIDERS[@]}")
FILTER="[${FILTER%,}]"

jq --argjson us_providers "$FILTER" '
  .data
  | map(select(.slug as $s | $us_providers | index($s)))
  | map(.slug)
' "${OUTPUT_DIR}/providers.json" > "${OUTPUT_DIR}/us-providers.json"

echo "US providers saved to us-providers.json:"
cat "${OUTPUT_DIR}/us-providers.json"
