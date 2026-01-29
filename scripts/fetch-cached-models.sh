#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/.."

echo "Fetching models from OpenRouter API..."

# Fetch all models
MODELS=$(curl -fsS "https://openrouter.ai/api/v1/models")

echo "Filtering for models with caching support..."

# Filter models:
# - Has pricing.input_cache_read (indicates caching support)
# - Excludes anthropic/*, google/* models (buy direct)
# - Excludes openai/gpt-5*, openai/o* models (proprietary)
echo "$MODELS" | jq '
  .data
  | map(select(
      .pricing.input_cache_read != null
      and .pricing.input_cache_read != "0"
      and (.id | startswith("anthropic/") | not)
      and (.id | startswith("google/") | not)
      and (.id | test("^openai/(gpt-5|o[0-9])") | not)
  ))
  | map(.id)
  | sort
' > "${OUTPUT_DIR}/cached-models.json"

COUNT=$(jq 'length' "${OUTPUT_DIR}/cached-models.json")
echo "Found ${COUNT} cached models. Saved to cached-models.json"
echo ""
echo "Models:"
jq -r '.[]' "${OUTPUT_DIR}/cached-models.json"
