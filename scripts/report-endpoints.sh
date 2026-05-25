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

if [[ -z "${OPENROUTER_PROVISIONING_KEY:-}" ]]; then
  echo "Error: OPENROUTER_PROVISIONING_KEY environment variable is required" >&2
  exit 1
fi

if [[ ! -f "${OUTPUT_DIR}/us-providers.json" ]]; then
  echo "Error: us-providers.json not found. Run ./scripts/fetch-providers.sh first." >&2
  exit 1
fi

US_PROVIDERS=$(jq -c '.' "${OUTPUT_DIR}/us-providers.json")
MODELS_RESPONSE=$(curl -fsS "${API_BASE}/models")

HEADER="model,name,parameter_size,parameter_count_billions,context_length,provider,region,quantization,model_provider_allowed,reasoning_supported,context_window_ok,endpoint_api_ok,us_provider_ok,us_region_ok,cacheable,latency_p50_ok,throughput_p50_ok,final_included,latency_p50_ms,throughput_p50_tps"
echo "$HEADER"

MODEL_IDS=( $(echo "$MODELS_RESPONSE" | jq -r '.data[].id') )

for MODEL_ID in "${MODEL_IDS[@]}"; do
  AUTHOR="${MODEL_ID%%/*}"
  SLUG="${MODEL_ID#*/}"
  MODEL_DETAIL=$(echo "$MODELS_RESPONSE" | jq -c --arg model "$MODEL_ID" '.data[] | select(.id == $model)')

  RESPONSE=$(curl -sS -H "Authorization: Bearer ${OPENROUTER_PROVISIONING_KEY}" \
    -w '\n%{http_code}' \
    "${API_BASE}/models/${AUTHOR}/${SLUG}/endpoints")

  STATUS_CODE="${RESPONSE##*$'\n'}"
  BODY="${RESPONSE%$'\n'*}"

  if [[ "$STATUS_CODE" != "200" ]] || ! echo "$BODY" | jq -e '.data.endpoints' >/dev/null 2>&1; then
    jq -r -n \
      --argjson model_detail "$MODEL_DETAIL" \
      --argjson include_openai "$(bool_json "$INCLUDE_OPENAI")" \
      --argjson include_google "$(bool_json "$INCLUDE_GOOGLE")" \
      --argjson include_anthropic "$(bool_json "$INCLUDE_ANTHROPIC")" \
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
          | if $match == null then {parameter_size: null, parameter_count_billions: null}
            else {parameter_size: $match.parameter_size, parameter_count_billions: $match.parameter_count_billions}
            end;
        def reasoning_supported:
          (((.supported_parameters // []) | index("reasoning")) != null)
          or (((.supported_parameters // []) | index("include_reasoning")) != null);
        def model_provider_allowed:
          ($include_anthropic or (.id | startswith("anthropic/") | not))
          and ($include_google or (.id | startswith("google/") | not));
        $model_detail
        | inferred_parameter_size as $params
        | model_provider_allowed as $model_provider_allowed
        | reasoning_supported as $reasoning_supported
        | ((.context_length? | tonumber? // 0) >= 128000) as $context_window_ok
        | [
            .id,
            (.name? // ""),
            ($params.parameter_size // ""),
            ($params.parameter_count_billions // ""),
            (.context_length? // ""),
            "",
            "",
            "",
            ($model_provider_allowed | tostring),
            ($reasoning_supported | tostring),
            ($context_window_ok | tostring),
            "false",
            "false",
            "false",
            "false",
            "false",
            "false",
            "false",
            "",
            ""
          ]
        | @csv
      '
    continue
  fi

  echo "$BODY" | jq -r \
    --argjson model_detail "$MODEL_DETAIL" \
    --argjson include_openai "$(bool_json "$INCLUDE_OPENAI")" \
    --argjson include_google "$(bool_json "$INCLUDE_GOOGLE")" \
    --argjson include_anthropic "$(bool_json "$INCLUDE_ANTHROPIC")" \
    --argjson min_tp "$MIN_THROUGHPUT_P50" \
    --argjson max_lat "$MAX_LATENCY_P50" \
    --argjson us_providers "$US_PROVIDERS" \
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
        | if $match == null then {parameter_size: null, parameter_count_billions: null}
          else {parameter_size: $match.parameter_size, parameter_count_billions: $match.parameter_count_billions}
          end;
      def reasoning_supported:
        (((.supported_parameters // []) | index("reasoning")) != null)
        or (((.supported_parameters // []) | index("include_reasoning")) != null);
      def model_family_allowed:
        ($include_anthropic or (.id | startswith("anthropic/") | not))
        and ($include_google or (.id | startswith("google/") | not));
      def endpoint_provider_allowed($provider):
        $include_openai or ($provider != "openai");
      def endpoint_objects:
        (.data.endpoints // [])
        | if type == "array" then . else [] end
        | [ .[] | if type == "array" then .[] else . end ]
        | map(select(type == "object"));
      def non_us_region_suffix:
        ascii_downcase as $suffix
        | (
            (($suffix | test("^[a-z][a-z]($|-)")) and (($suffix | startswith("us")) | not))
            or ($suffix | startswith("europe"))
            or ($suffix == "asia")
            or ($suffix | startswith("asia-"))
            or ($suffix == "ap")
            or ($suffix | startswith("ap-"))
          );
      def us_region_suffix:
        ascii_downcase | startswith("us");
      def endpoint_parts:
        (.tag? // "" | split("/")) as $parts
        | ($parts[1:] // []) as $suffixes
        | {
            provider: ($parts[0] // ""),
            region: (
              $suffixes
              | map(select((. | us_region_suffix) or (. | non_us_region_suffix)))
              | first // ""
            ),
            has_non_us_region: (($suffixes | map(select(non_us_region_suffix)) | length) > 0)
          };

      $model_detail as $m
      | ($m | inferred_parameter_size) as $params
      | ($m | model_family_allowed) as $model_family_allowed
      | ($m | reasoning_supported) as $reasoning_supported
      | (($m.context_length? | tonumber? // 0) >= 128000) as $context_window_ok
      | endpoint_objects
      | if length == 0 then [null] else . end
      | map(
          . as $e
          | ($e | endpoint_parts) as $endpoint
          | ($model_family_allowed and endpoint_provider_allowed($endpoint.provider)) as $model_provider_allowed
          | ($endpoint.provider as $provider | ($us_providers | index($provider)) != null) as $us_provider_ok
          | ($endpoint.has_non_us_region | not) as $us_region_ok
          | ($e != null and $e.pricing.input_cache_read? != null and $e.pricing.input_cache_read? != "0") as $cacheable
          | ($e.latency_last_30m.p50? // null) as $lat
          | ($e.throughput_last_30m.p50? // null) as $tp
          # Mercury 2 and Google Flash models can have null public endpoint perf fields
          # even when provider pages expose healthy routing heuristics.
          | (
              ($m.id == "inception/mercury-2")
              or (
                (($m.id | startswith("google/")) or ($m.id | startswith("~google/")))
                and ($m.id | ascii_downcase | contains("flash"))
              )
            ) as $performance_exempt
          | ($performance_exempt or ($lat != null and $lat <= $max_lat)) as $latency_p50_ok
          | ($performance_exempt or ($tp != null and $tp >= $min_tp)) as $throughput_p50_ok
          | (
              $model_provider_allowed
              and $reasoning_supported
              and $context_window_ok
              and $us_provider_ok
              and $us_region_ok
              and $cacheable
              and $latency_p50_ok
              and $throughput_p50_ok
            ) as $final_included
          | [
              $m.id,
              ($m.name? // ""),
              ($params.parameter_size // ""),
              ($params.parameter_count_billions // ""),
              ($m.context_length? // ""),
              $endpoint.provider,
              $endpoint.region,
              ($e.quantization? // ""),
              ($model_provider_allowed | tostring),
              ($reasoning_supported | tostring),
              ($context_window_ok | tostring),
              "true",
              ($us_provider_ok | tostring),
              ($us_region_ok | tostring),
              ($cacheable | tostring),
              ($latency_p50_ok | tostring),
              ($throughput_p50_ok | tostring),
              ($final_included | tostring),
              ($lat // ""),
              ($tp // "")
            ]
          | @csv
        )
      | .[]
    '
done
