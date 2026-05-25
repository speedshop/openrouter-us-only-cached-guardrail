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

CACHED_MODELS=$(jq -c '.' "${OUTPUT_DIR}/cached-models.json")
MODELS=( $(echo "$CACHED_MODELS" | jq -r '.[]') )
US_PROVIDERS=$(jq -c '.' "${OUTPUT_DIR}/allowed-providers.json")

HEADER="model,parameter_size,parameter_count_billions,provider,quantization,cacheable,latency_p50_ms,throughput_p50_tps,passes"
echo "$HEADER"

if [[ "${#MODELS[@]}" -eq 0 ]]; then
  echo "No cached models to report. cached-models.json is empty." >&2
  exit 0
fi

MODEL_DETAILS=$(curl -fsS "${API_BASE}/models" | jq \
  --argjson selected "$CACHED_MODELS" \
  '
    def parameter_match_objects($matches):
      $matches
      | map({
          value: (.captures[] | select(.name == "value") | .string | tonumber),
          unit: (.captures[] | select(.name == "unit") | .string | ascii_downcase)
        })
      | map(. + {
          parameter_count_billions: (if .unit == "b" then .value else (.value / 1000) end),
          parameter_size: ((.value | tostring) + (.unit | ascii_upcase))
        });

    def parameter_matches:
      (
        [(.name? // ""), (.hugging_face_id? // ""), (.canonical_slug? // ""), (.id? // "")]
        | join(" ")
        | [match("(?i)(^|[^[:alnum:]])(?<value>[0-9]+(?:\\.[0-9]+)?)\\s*b(?:[^[:alnum:]]|$)"; "g")]
        | parameter_match_objects(map(.captures += [{name: "unit", string: "b", offset: 0, length: 1}]))
      )
      +
      (
        (.description? // "")
        | [match("(?i)(^|[^[:alnum:]])(?<value>[0-9]+(?:\\.[0-9]+)?)\\s*(?<unit>[bm])(?:\\s|-)?(?:parameters?|params?)\\b"; "g")]
        | parameter_match_objects(.)
      );

    def inferred_parameter_size:
      (parameter_matches | if length == 0 then null else max_by(.parameter_count_billions) end) as $match
      | if $match == null then
          {parameter_size: null, parameter_count_billions: null}
        else
          {
            parameter_size: $match.parameter_size,
            parameter_count_billions: $match.parameter_count_billions
          }
        end;

    .data
    | map(select(.id as $id | $selected | index($id)))
    | map({key: .id, value: inferred_parameter_size})
    | from_entries
  ')

for MODEL_ID in "${MODELS[@]}"; do
  AUTHOR="${MODEL_ID%%/*}"
  SLUG="${MODEL_ID#*/}"

  RESPONSE=$(curl -sS -H "Authorization: Bearer ${OPENROUTER_PROVISIONING_KEY}" \
    "${API_BASE}/models/${AUTHOR}/${SLUG}/endpoints")

  PARAMETER_SIZE=$(echo "$MODEL_DETAILS" | jq -r --arg model "$MODEL_ID" '.[$model].parameter_size // ""')
  PARAMETER_COUNT_BILLIONS=$(echo "$MODEL_DETAILS" | jq -r --arg model "$MODEL_ID" '.[$model].parameter_count_billions // ""')

  echo "$RESPONSE" | jq -r \
    --arg model "$MODEL_ID" \
    --arg parameter_size "$PARAMETER_SIZE" \
    --arg parameter_count_billions "$PARAMETER_COUNT_BILLIONS" \
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
              $parameter_size,
              $parameter_count_billions,
              ($e.tag? // ""),
              ($e.quantization? // ""),
              ($cacheable | tostring),
              ($lat | tostring),
              ($tp | tostring),
              ($passes | tostring)
            ]
          | @csv
        )
      | .[]
    '
done
