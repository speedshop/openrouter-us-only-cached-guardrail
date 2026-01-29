#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/.."
API_BASE="https://openrouter.ai/api/v1"

MIN_THROUGHPUT_P50="${OPENROUTER_MIN_THROUGHPUT_P50:-50}"
MAX_LATENCY_P50="${OPENROUTER_MAX_LATENCY_P50:-2000}"

if [[ -z "${OPENROUTER_PROVISIONING_KEY:-}" ]]; then
  echo "Error: OPENROUTER_PROVISIONING_KEY environment variable is required" >&2
  exit 1
fi

if [[ ! -f "${OUTPUT_DIR}/cached-models.json" ]]; then
  echo "Error: cached-models.json not found. Run ./scripts/fetch-cached-models.sh first." >&2
  exit 1
fi

if [[ ! -f "${OUTPUT_DIR}/allowed-providers.json" ]]; then
  echo "Error: allowed-providers.json not found. Run ./scripts/fetch-cached-models.sh first." >&2
  exit 1
fi

MODELS=( $(jq -r '.[]' "${OUTPUT_DIR}/cached-models.json") )
US_PROVIDERS=$(jq -c '.' "${OUTPUT_DIR}/allowed-providers.json")

if [[ "${#MODELS[@]}" -eq 0 ]]; then
  echo "No cached models to report. cached-models.json is empty." >&2
  exit 0
fi

echo "model\tprovider\tquantization\tcacheable\tlatency_p50_ms\tthroughput_p50_tps\tpasses"

for MODEL_ID in "${MODELS[@]}"; do
  AUTHOR="${MODEL_ID%%/*}"
  SLUG="${MODEL_ID#*/}"

  RESPONSE=$(curl -sS -H "Authorization: Bearer ${OPENROUTER_PROVISIONING_KEY}" \
    "${API_BASE}/models/${AUTHOR}/${SLUG}/endpoints")

  echo "$RESPONSE" | jq -r \
    --arg model "$MODEL_ID" \
    --argjson min_tp "$MIN_THROUGHPUT_P50" \
    --argjson max_lat "$MAX_LATENCY_P50" \
    --argjson providers "$US_PROVIDERS" \
    '
      def endpoint_objects:
        (.data.endpoints // [])
        | if type == "array" then . else [] end
        | [ .[] | if type == "array" then .[] else . end ]
        | map(select(type == "object"));
      endpoint_objects
      | map(select((.tag? // "" | split("/")[0]) as $tag | ($providers | index($tag))))
      | map(
          . as $e
          | ($e.pricing.input_cache_read? != null and $e.pricing.input_cache_read? != "0") as $cacheable
          | ($e.latency_last_30m.p50? // 1e9) as $lat
          | ($e.throughput_last_30m.p50? // -1) as $tp
          | ($cacheable and $lat <= $max_lat and $tp >= $min_tp) as $passes
          | [
              $model,
              ($e.tag? // ""),
              ($e.quantization? // ""),
              ($cacheable | tostring),
              ($lat | tostring),
              ($tp | tostring),
              ($passes | tostring)
            ]
          | @tsv
        )
      | .[]
    '
 done
