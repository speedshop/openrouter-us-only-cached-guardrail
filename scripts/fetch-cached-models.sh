#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/.."
API_BASE="https://openrouter.ai/api/v1"

MIN_THROUGHPUT_P50="${OPENROUTER_MIN_THROUGHPUT_P50:-50}"
MAX_LATENCY_P50="${OPENROUTER_MAX_LATENCY_P50:-2}"

echo "Fetching models from OpenRouter API..."

# Fetch all models
MODELS=$(curl -fsS "https://openrouter.ai/api/v1/models")

echo "Filtering for models with caching support..."

# Filter models:
# - Has pricing.input_cache_read (indicates caching support)
# - Excludes anthropic/*, google/* models (buy direct)
# - Excludes openai/gpt-5*, openai/o* models (proprietary)
BASE_MODELS=$(echo "$MODELS" | jq '
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
')

if [[ -z "${OPENROUTER_PROVISIONING_KEY:-}" ]]; then
  echo "Warning: OPENROUTER_PROVISIONING_KEY not set. Skipping performance filter."
  echo "$BASE_MODELS" > "${OUTPUT_DIR}/cached-models.json"
  echo "$BASE_MODELS" > "${OUTPUT_DIR}/available-models.json"
else
  if [[ ! -f "${OUTPUT_DIR}/us-providers.json" ]]; then
    echo "Error: us-providers.json not found. Run ./scripts/fetch-providers.sh first."
    exit 1
  fi

  US_PROVIDERS=$(jq -c '.' "${OUTPUT_DIR}/us-providers.json")

  echo "Filtering for endpoints with caching + performance thresholds..."
  echo "Minimum throughput (p50): ${MIN_THROUGHPUT_P50} tok/sec"
  echo "Maximum latency (p50): ${MAX_LATENCY_P50} sec"

  AVAILABLE_MODELS=()
  FILTERED_MODELS=()

  while read -r MODEL_ID; do
    AUTHOR="${MODEL_ID%%/*}"
    SLUG="${MODEL_ID#*/}"

    RESPONSE=$(curl -sS -H "Authorization: Bearer ${OPENROUTER_PROVISIONING_KEY}" \
      -w '\n%{http_code}' \
      "${API_BASE}/models/${AUTHOR}/${SLUG}/endpoints")

    STATUS_CODE="${RESPONSE##*$'\n'}"
    BODY="${RESPONSE%$'\n'*}"

    if [[ "$STATUS_CODE" != "200" ]]; then
      if [[ "$STATUS_CODE" == "401" || "$STATUS_CODE" == "403" ]]; then
        echo "Error: endpoints API unauthorized. Check OPENROUTER_PROVISIONING_KEY."
        exit 1
      fi
      echo "Skipping ${MODEL_ID} (endpoints API returned ${STATUS_CODE})"
      continue
    fi

    if ! echo "$BODY" | jq -e '.data.endpoints' >/dev/null; then
      echo "Skipping ${MODEL_ID} (invalid endpoints response)"
      continue
    fi

    MATCHES_US=$(echo "$BODY" | jq \
      --argjson us_providers "$US_PROVIDERS" \
      '
        .data.endpoints // []
        | map(select(
            ($us_providers | index(.tag))
          ))
        | length
      ')

    MATCHES_PERF=$(echo "$BODY" | jq \
      --argjson min_tp "$MIN_THROUGHPUT_P50" \
      --argjson max_lat "$MAX_LATENCY_P50" \
      --argjson us_providers "$US_PROVIDERS" \
      '
        .data.endpoints // []
        | map(select(
            (.throughput_last_30m.p50? // -1) >= $min_tp
            and (.latency_last_30m.p50? // 1e9) <= $max_lat
            and ($us_providers | index(.tag))
          ))
        | length
      ')

    if [[ "$MATCHES_PERF" -gt 0 ]]; then
      FILTERED_MODELS+=("$MODEL_ID")
      AVAILABLE_MODELS+=("$MODEL_ID")
    fi
  done < <(echo "$BASE_MODELS" | jq -r '.[]')

  if [[ "${#FILTERED_MODELS[@]}" -eq 0 ]]; then
    echo "Warning: no models met the performance thresholds."
  fi

  printf '%s\n' "${FILTERED_MODELS[@]}" | jq -R . | jq -s 'sort' > "${OUTPUT_DIR}/cached-models.json"
  printf '%s\n' "${AVAILABLE_MODELS[@]}" | jq -R . | jq -s 'sort' > "${OUTPUT_DIR}/available-models.json"
fi

COUNT=$(jq 'length' "${OUTPUT_DIR}/cached-models.json")
echo "Found ${COUNT} cached models. Saved to cached-models.json"
echo ""
echo "Models:"
jq -r '.[]' "${OUTPUT_DIR}/cached-models.json"
