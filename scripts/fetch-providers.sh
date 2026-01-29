#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/.."

echo "Fetching providers from OpenRouter API..."

# Fetch raw provider data
curl -fsS "https://openrouter.ai/api/v1/providers" | jq '.' > "${OUTPUT_DIR}/providers.json"

# US-based providers (from https://openrouter.ai/providers)
# Excludes: openai, anthropic
US_PROVIDERS=(
  "amazon-bedrock"
  "arcee-ai"
  "atlas-cloud"
  "azure"
  "baseten"
  "cerebras"
  "chutes"
  "clarifai"
  "cloudflare"
  "cohere"
  "crusoe"
  "deepinfra"
  "featherless"
  "fireworks"
  "friendli"
  "gmicloud"
  "google-ai-studio"
  "google-vertex"
  "groq"
  "hyperbolic"
  "modelrun"
  "morph"
  "novita"
  "nvidia"
  "open-inference"
  "parasail"
  "perplexity"
  "phala"
  "sambanova"
  "switchpoint"
  "together"
  "wandb"
  "xai"
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
