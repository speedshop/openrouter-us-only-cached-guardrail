#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/.."
API_BASE="https://openrouter.ai/api/v1"

MIN_THROUGHPUT_P50="${OPENROUTER_MIN_THROUGHPUT_P50:-50}"
MAX_LATENCY_P50="${OPENROUTER_MAX_LATENCY_P50:-2000}"
INCLUDE_OPENAI="${OPENROUTER_INCLUDE_OPENAI:-false}"
INCLUDE_GOOGLE="${OPENROUTER_INCLUDE_GOOGLE:-true}"
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

write_available_models() {
  local selected_json="$1"

  echo "$MODELS" | jq \
    --argjson selected "$selected_json" \
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
      | map({
          id,
          name,
          context_length,
          parameter_size: inferred_parameter_size.parameter_size,
          parameter_count_billions: inferred_parameter_size.parameter_count_billions,
          hugging_face_id,
          canonical_slug
        })
      | sort_by(.id)
    ' > "${OUTPUT_DIR}/available-models.json"
}

# Filter models:
# - Excludes openai/anthropic by default; Google is included by default (toggle via env vars)
# - Requires OpenRouter reasoning/thinking support
# - Requires a context window of at least 128k tokens
ALL_MODELS=$(echo "$MODELS" | jq '[.data[].id] | unique | sort')
PROVIDER_MODELS=$(echo "$MODELS" | jq \
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
REASONING_MODELS=$(echo "$MODELS" | jq \
  --argjson provider_models "$PROVIDER_MODELS" \
  '
  def reasoning_model:
    (((.supported_parameters // []) | index("reasoning")) != null)
    or (((.supported_parameters // []) | index("include_reasoning")) != null);

  .data
  | map(select((.id as $id | $provider_models | index($id)) and reasoning_model))
  | map(.id)
  | sort
')
BASE_MODELS=$(echo "$MODELS" | jq \
  --argjson reasoning_models "$REASONING_MODELS" \
  '
  def context_window:
    .context_length? | tonumber? // 0;

  .data
  | map(select((.id as $id | $reasoning_models | index($id)) and (context_window >= 128000)))
  | map(.id)
  | sort
')

EXCLUDED_PROVIDER_FILTER=$(jq -n \
  --argjson cached "$ALL_MODELS" \
  --argjson provider "$PROVIDER_MODELS" \
  '$cached | map(select($provider | index(.) | not))')

if [[ "$(echo "$EXCLUDED_PROVIDER_FILTER" | jq 'length')" -gt 0 ]]; then
  echo "Excluded (provider allowlist):"
  echo "$EXCLUDED_PROVIDER_FILTER" | jq -c '.'
fi

EXCLUDED_REASONING_FILTER=$(jq -n \
  --argjson provider "$PROVIDER_MODELS" \
  --argjson reasoning "$REASONING_MODELS" \
  '$provider | map(select($reasoning | index(.) | not))')

if [[ "$(echo "$EXCLUDED_REASONING_FILTER" | jq 'length')" -gt 0 ]]; then
  echo "Excluded (no reasoning/thinking support):"
  echo "$EXCLUDED_REASONING_FILTER" | jq -c '.'
fi

EXCLUDED_CONTEXT_FILTER=$(jq -n \
  --argjson reasoning "$REASONING_MODELS" \
  --argjson base "$BASE_MODELS" \
  '$reasoning | map(select($base | index(.) | not))')

if [[ "$(echo "$EXCLUDED_CONTEXT_FILTER" | jq 'length')" -gt 0 ]]; then
  echo "Excluded (context window < 128k tokens):"
  echo "$EXCLUDED_CONTEXT_FILTER" | jq -c '.'
fi

if [[ -z "${OPENROUTER_PROVISIONING_KEY:-}" ]]; then
  echo "Warning: OPENROUTER_PROVISIONING_KEY not set. Skipping performance filter."
  echo "$BASE_MODELS" > "${OUTPUT_DIR}/cached-models.json"
  write_available_models "$BASE_MODELS"
else
  if [[ ! -f "${OUTPUT_DIR}/us-providers.json" ]]; then
    echo "Error: us-providers.json not found. Run ./scripts/fetch-providers.sh first."
    exit 1
  fi

  US_PROVIDERS=$(jq -c '.' "${OUTPUT_DIR}/us-providers.json")

  echo "Filtering for endpoints with reasoning/thinking support + 128k context window + caching + performance thresholds..."
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
        def allowed_us_endpoint($providers):
          (.tag? // "" | split("/")) as $parts
          | ($parts[0]) as $provider
          | ($parts[1] // "") as $region
          | ($providers | index($provider))
          and ($region == "" or ($region | startswith("us")));
        endpoint_objects
        | map(select(
            allowed_us_endpoint($us_providers)
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
        def allowed_us_endpoint($providers):
          (.tag? // "" | split("/")) as $parts
          | ($parts[0]) as $provider
          | ($parts[1] // "") as $region
          | ($providers | index($provider))
          and ($region == "" or ($region | startswith("us")));
        endpoint_objects
        | map(select(
            allowed_us_endpoint($us_providers)
            and (.pricing.input_cache_read? != null)
            and (.pricing.input_cache_read? != "0")
          ))
        | length
      ')

    if [[ "$MATCHES_CACHE" -eq 0 ]]; then
      EXCLUDED_NO_CACHE+=("$MODEL_ID")
      continue
    fi

    # Mercury 2 and Google Flash models can have null public endpoint perf fields
    # even when provider pages expose healthy routing heuristics.
    MATCHES_PERF=$(echo "$BODY" | jq \
      --arg model_id "$MODEL_ID" \
      --argjson min_tp "$MIN_THROUGHPUT_P50" \
      --argjson max_lat "$MAX_LATENCY_P50" \
      --argjson us_providers "$US_PROVIDERS" \
      '
        def endpoint_objects:
          (.data.endpoints // [])
          | if type == "array" then . else [] end
          | [ .[] | if type == "array" then .[] else . end ]
          | map(select(type == "object"));
        def allowed_us_endpoint($providers):
          (.tag? // "" | split("/")) as $parts
          | ($parts[0]) as $provider
          | ($parts[1] // "") as $region
          | ($providers | index($provider))
          and ($region == "" or ($region | startswith("us")));
        def performance_exempt:
          ($model_id == "inception/mercury-2")
          or (
            (($model_id | startswith("google/")) or ($model_id | startswith("~google/")))
            and ($model_id | ascii_downcase | contains("flash"))
          );
        def performance_ok:
          performance_exempt
          or (
            (.throughput_last_30m.p50? // -1) >= $min_tp
            and (.latency_last_30m.p50? // 1e9) <= $max_lat
          );
        endpoint_objects
        | map(select(
            performance_ok
            and allowed_us_endpoint($us_providers)
            and (.pricing.input_cache_read? != null)
            and (.pricing.input_cache_read? != "0")
          ))
        | length
      ')

    if [[ "$MATCHES_PERF" -gt 0 ]]; then
      FILTERED_MODELS+=("$MODEL_ID")
      AVAILABLE_MODELS+=("$MODEL_ID")
      MATCHING_PROVIDERS=$(echo "$BODY" | jq -r \
        --arg model_id "$MODEL_ID" \
        --argjson min_tp "$MIN_THROUGHPUT_P50" \
        --argjson max_lat "$MAX_LATENCY_P50" \
        --argjson us_providers "$US_PROVIDERS" \
        '
          def endpoint_objects:
            (.data.endpoints // [])
            | if type == "array" then . else [] end
            | [ .[] | if type == "array" then .[] else . end ]
            | map(select(type == "object"));
          def allowed_us_endpoint($providers):
            (.tag? // "" | split("/")) as $parts
            | ($parts[0]) as $provider
            | ($parts[1] // "") as $region
            | ($providers | index($provider))
            and ($region == "" or ($region | startswith("us")));
          def performance_exempt:
            ($model_id == "inception/mercury-2")
            or (
              (($model_id | startswith("google/")) or ($model_id | startswith("~google/")))
              and ($model_id | ascii_downcase | contains("flash"))
            );
          def performance_ok:
            performance_exempt
            or (
              (.throughput_last_30m.p50? // -1) >= $min_tp
              and (.latency_last_30m.p50? // 1e9) <= $max_lat
            );
          endpoint_objects
          | map(select(
              performance_ok
              and allowed_us_endpoint($us_providers)
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
    AVAILABLE_MODELS_JSON=$(printf '%s\n' "${AVAILABLE_MODELS[@]}" | jq -R . | jq -s 'sort')
    write_available_models "$AVAILABLE_MODELS_JSON"
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

if [[ -f "${OUTPUT_DIR}/available-models.json" ]]; then
  echo ""
  echo "Available model details:"
  jq -r '.[] | "\(.id)\t\(.parameter_size // "unknown")\t\(.context_length // "unknown") context"' "${OUTPUT_DIR}/available-models.json"
fi
