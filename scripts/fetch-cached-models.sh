#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/.."
API_BASE="https://openrouter.ai/api/v1"

MIN_THROUGHPUT_P50="${OPENROUTER_MIN_THROUGHPUT_P50:-50}"
MAX_LATENCY_P50="${OPENROUTER_MAX_LATENCY_P50:-2000}"
INCLUDE_OPENAI="${OPENROUTER_INCLUDE_OPENAI:-false}"
INCLUDE_GOOGLE="${OPENROUTER_INCLUDE_GOOGLE:-false}"
INCLUDE_ANTHROPIC="${OPENROUTER_INCLUDE_ANTHROPIC:-false}"

bool_json() {
  if [[ "${1:-}" == "true" || "${1:-}" == "1" || "${1:-}" == "yes" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

echo "Fetching models from OpenRouter API..."

# Fetch all models
MODELS=$(curl -fsS "https://openrouter.ai/api/v1/models")

echo "Filtering for models..."

# Filter models:
# - Excludes openai/google/anthropic by default (toggle via env vars)
ALL_MODELS=$(echo "$MODELS" | jq '[.data[].id] | unique | sort')
BASE_MODELS=$(echo "$MODELS" | jq \
  --argjson include_openai "$(bool_json "$INCLUDE_OPENAI")" \
  --argjson include_google "$(bool_json "$INCLUDE_GOOGLE")" \
  --argjson include_anthropic "$(bool_json "$INCLUDE_ANTHROPIC")" \
  '
  .data
  | map(select(
      ($include_anthropic or (.id | startswith("anthropic/") | not))
      and ($include_google or (.id | startswith("google/") | not))
      and ($include_openai or (.id | startswith("openai/") | not))
  ))
  | map(.id)
  | sort
')

EXCLUDED_PROVIDER_FILTER=$(jq -n \
  --argjson cached "$ALL_MODELS" \
  --argjson base "$BASE_MODELS" \
  '$cached | map(select($base | index(.) | not))')

if [[ "$(echo "$EXCLUDED_PROVIDER_FILTER" | jq 'length')" -gt 0 ]]; then
  echo "Excluded (provider allowlist):"
  echo "$EXCLUDED_PROVIDER_FILTER" | jq -c '.'
fi

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
  echo "Maximum latency (p50): ${MAX_LATENCY_P50} ms"

  EXCLUDED_ENDPOINTS_ERROR=()
  EXCLUDED_NO_US=()
  EXCLUDED_NO_CACHE=()
  EXCLUDED_PERF=()
  PROVIDERS_WITH_MATCHES=()
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
      EXCLUDED_ENDPOINTS_ERROR+=("$MODEL_ID")
      continue
    fi

    if ! echo "$BODY" | jq -e '.data.endpoints' >/dev/null; then
      echo "Skipping ${MODEL_ID} (invalid endpoints response)"
      EXCLUDED_ENDPOINTS_ERROR+=("$MODEL_ID")
      continue
    fi

    MATCHES_US=$(echo "$BODY" | jq \
      --argjson us_providers "$US_PROVIDERS" \
      '
        def endpoint_objects:
          (.data.endpoints // [])
          | if type == "array" then . else [] end
          | [ .[] | if type == "array" then .[] else . end ]
          | map(select(type == "object"));
        endpoint_objects
        | map(select(
            (.tag? // "" | split("/")[0]) as $tag
            | ($us_providers | index($tag))
          ))
        | length
      ')

    if [[ "$MATCHES_US" -eq 0 ]]; then
      EXCLUDED_NO_US+=("$MODEL_ID")
      continue
    fi

    MATCHES_CACHE=$(echo "$BODY" | jq \
      --argjson us_providers "$US_PROVIDERS" \
      '
        def endpoint_objects:
          (.data.endpoints // [])
          | if type == "array" then . else [] end
          | [ .[] | if type == "array" then .[] else . end ]
          | map(select(type == "object"));
        endpoint_objects
        | map(select(
            ((.tag? // "" | split("/")[0]) as $tag | ($us_providers | index($tag)))
            and (.pricing.input_cache_read? != null)
            and (.pricing.input_cache_read? != "0")
          ))
        | length
      ')

    if [[ "$MATCHES_CACHE" -eq 0 ]]; then
      EXCLUDED_NO_CACHE+=("$MODEL_ID")
      continue
    fi

    MATCHES_PERF=$(echo "$BODY" | jq \
      --argjson min_tp "$MIN_THROUGHPUT_P50" \
      --argjson max_lat "$MAX_LATENCY_P50" \
      --argjson us_providers "$US_PROVIDERS" \
      '
        def endpoint_objects:
          (.data.endpoints // [])
          | if type == "array" then . else [] end
          | [ .[] | if type == "array" then .[] else . end ]
          | map(select(type == "object"));
        endpoint_objects
        | map(select(
            (.throughput_last_30m.p50? // -1) >= $min_tp
            and (.latency_last_30m.p50? // 1e9) <= $max_lat
            and ((.tag? // "" | split("/")[0]) as $tag | ($us_providers | index($tag)))
            and (.pricing.input_cache_read? != null)
            and (.pricing.input_cache_read? != "0")
          ))
        | length
      ')

    if [[ "$MATCHES_PERF" -gt 0 ]]; then
      FILTERED_MODELS+=("$MODEL_ID")
      AVAILABLE_MODELS+=("$MODEL_ID")
      MATCHING_PROVIDERS=$(echo "$BODY" | jq -r \
        --argjson min_tp "$MIN_THROUGHPUT_P50" \
        --argjson max_lat "$MAX_LATENCY_P50" \
        --argjson us_providers "$US_PROVIDERS" \
        '
          def endpoint_objects:
            (.data.endpoints // [])
            | if type == "array" then . else [] end
            | [ .[] | if type == "array" then .[] else . end ]
            | map(select(type == "object"));
          endpoint_objects
          | map(select(
              (.throughput_last_30m.p50? // -1) >= $min_tp
              and (.latency_last_30m.p50? // 1e9) <= $max_lat
              and ((.tag? // "" | split("/")[0]) as $tag | ($us_providers | index($tag)))
              and (.pricing.input_cache_read? != null)
              and (.pricing.input_cache_read? != "0")
            ))
          | map(.tag? // "" | split("/")[0])
          | unique
          | .[]
        ')
      while read -r PROVIDER_TAG; do
        if [[ -n "$PROVIDER_TAG" ]]; then
          PROVIDERS_WITH_MATCHES+=("$PROVIDER_TAG")
        fi
      done < <(printf '%s\n' "$MATCHING_PROVIDERS")
    else
      EXCLUDED_PERF+=("$MODEL_ID")
    fi
  done < <(echo "$BASE_MODELS" | jq -r '.[]')

  if [[ "${#EXCLUDED_ENDPOINTS_ERROR[@]}" -gt 0 ]]; then
    echo "Excluded (endpoints error):"
    printf '%s\n' "${EXCLUDED_ENDPOINTS_ERROR[@]}" | jq -R . | jq -s 'sort'
  fi

  if [[ "${#EXCLUDED_NO_US[@]}" -gt 0 ]]; then
    echo "Excluded (no US endpoints):"
    printf '%s\n' "${EXCLUDED_NO_US[@]}" | jq -R . | jq -s 'sort'
  fi

  if [[ "${#EXCLUDED_NO_CACHE[@]}" -gt 0 ]]; then
    echo "Excluded (no cacheable US endpoints):"
    printf '%s\n' "${EXCLUDED_NO_CACHE[@]}" | jq -R . | jq -s 'sort'
  fi

  if [[ "${#EXCLUDED_PERF[@]}" -gt 0 ]]; then
    echo "Excluded (below performance thresholds):"
    printf '%s\n' "${EXCLUDED_PERF[@]}" | jq -R . | jq -s 'sort'
  fi

  if [[ "${#FILTERED_MODELS[@]}" -eq 0 ]]; then
    echo "Warning: no models met the performance thresholds."
    echo "[]" > "${OUTPUT_DIR}/cached-models.json"
  else
    printf '%s\n' "${FILTERED_MODELS[@]}" | jq -R . | jq -s 'sort' > "${OUTPUT_DIR}/cached-models.json"
  fi

  if [[ "${#AVAILABLE_MODELS[@]}" -eq 0 ]]; then
    echo "[]" > "${OUTPUT_DIR}/available-models.json"
  else
    printf '%s\n' "${AVAILABLE_MODELS[@]}" | jq -R . | jq -s 'sort' > "${OUTPUT_DIR}/available-models.json"
  fi

  if [[ "${#PROVIDERS_WITH_MATCHES[@]}" -eq 0 ]]; then
    echo "[]" > "${OUTPUT_DIR}/allowed-providers.json"
  else
    printf '%s\n' "${PROVIDERS_WITH_MATCHES[@]}" | jq -R . | jq -s 'unique | sort' > "${OUTPUT_DIR}/allowed-providers.json"
  fi
fi

COUNT=$(jq 'length' "${OUTPUT_DIR}/cached-models.json")
echo "Found ${COUNT} cached models. Saved to cached-models.json"
echo ""
echo "Models:"
jq -r '.[]' "${OUTPUT_DIR}/cached-models.json"
