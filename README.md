# OpenRouter US-Only Cached Guardrail

Keep a guardrail up to date. It is for OpenRouter. The guardrail allows only US providers. It allows only models with prompt cache. It blocks OpenAI, Google, and Anthropic models. Use those APIs directly.

## Why use this

- Save cash with prompt cache.
- Keep data in the US.
- Keep up as new models show up.

> [!IMPORTANT]
> This action does not attach API keys to a guardrail. You still need to do that in OpenRouter.

## Use the shared workflow

Call this workflow from another repo:

```yaml
name: Update OpenRouter Guardrail

on:
  schedule:
    - cron: '0 6 * * *'
  workflow_dispatch:

concurrency:
  group: update-openrouter-guardrail
  cancel-in-progress: true

jobs:
  update:
    uses: speedshop/openrouter-us-only-cached-guardrail/.github/workflows/guardrail.yml@v1.1
    with:
      guardrail_name: ${{ vars.OPENROUTER_GUARDRAIL_NAME }}
      include_openai: "false"
      include_google: "false"
      include_anthropic: "false"
      upload_artifacts: "true"
    secrets:
      OPENROUTER_PROVISIONING_KEY: ${{ secrets.OPENROUTER_PROVISIONING_KEY }}
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `guardrail_name` | No | `US Cached Models Only` | Guardrail name |
| `min_throughput_p50` | No | `50` | Minimum throughput (p50, tok/sec) |
| `max_latency_p50` | No | `2` | Maximum latency (p50, seconds) |
| `include_openai` | No | `false` | Include OpenAI models and provider |
| `include_google` | No | `false` | Include Google models and providers |
| `include_anthropic` | No | `false` | Include Anthropic models and provider |
| `upload_artifacts` | No | `false` | Upload JSON files as artifacts (`us-providers.json`, `cached-models.json`, `available-models.json`) |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `OPENROUTER_PROVISIONING_KEY` | Yes | OpenRouter key |

## Use the action directly

Add a workflow in any repo where you want this to run:

```yaml
name: Update OpenRouter Guardrail

on:
  schedule:
    - cron: '0 6 * * *'
  workflow_dispatch:

concurrency:
  group: update-openrouter-guardrail
  cancel-in-progress: true

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - name: Update guardrail
        uses: speedshop/openrouter-us-only-cached-guardrail@v1.1
        with:
          provisioning_key: ${{ secrets.OPENROUTER_PROVISIONING_KEY }}
          guardrail_name: ${{ vars.OPENROUTER_GUARDRAIL_NAME }}
          include_openai: "false"
          include_google: "false"
          include_anthropic: "false"
          upload_artifacts: "true"
```

### Action inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `provisioning_key` | Yes | — | OpenRouter key |
| `guardrail_name` | No | `US Cached Models Only` | Guardrail name |
| `include_openai` | No | `false` | Include OpenAI models and provider |
| `include_google` | No | `false` | Include Google models and providers |
| `include_anthropic` | No | `false` | Include Anthropic models and provider |
| `upload_artifacts` | No | `false` | Upload JSON files as artifacts (`us-providers.json`, `cached-models.json`, `available-models.json`) |

## Secrets and vars

1. Add `OPENROUTER_PROVISIONING_KEY` as a secret:
   - **Settings > Secrets and variables > Actions**
   - Get the key from https://openrouter.ai/settings/keys
2. (Optional) Add `OPENROUTER_GUARDRAIL_NAME` as a variable:
   - **Settings > Secrets and variables > Actions**

## Local use

Run the scripts to test or debug:

```bash
./scripts/fetch-providers.sh
OPENROUTER_PROVISIONING_KEY="your-key-here" ./scripts/fetch-cached-models.sh

export OPENROUTER_PROVISIONING_KEY="your-key-here"
./scripts/update-guardrail.sh
```

## Rules

Default rules:

| Setting | Value |
|---------|-------|
| Name | US Cached Models Only (override with `OPENROUTER_GUARDRAIL_NAME`) |
| Providers | US only (OpenAI/Google/Anthropic excluded by default) |
| Models | Must support prompt cache |

## Performance filter

The model list is also filtered by endpoint performance (p50 over the last 30 minutes). Only endpoints from US providers count.

- Minimum throughput: 50 tok/sec
- Maximum latency: 2 sec

Override with env vars:

- `OPENROUTER_MIN_THROUGHPUT_P50`
- `OPENROUTER_MAX_LATENCY_P50`

Set these in your workflow or job `env` block.
If you use the shared workflow, set `min_throughput_p50` and `max_latency_p50` inputs.
This filter uses the OpenRouter endpoints API, so it needs `OPENROUTER_PROVISIONING_KEY`.

## Available models output

When `upload_artifacts` is on, the action also writes `available-models.json`.
It lists models that have at least one endpoint from an allowed US provider.

To change these rules, edit the scripts in `scripts/`.

## Directory structure

```
.github/workflows/   Reusable GitHub Actions workflow
action.yml           Reusable GitHub Action (composite)
scripts/             Shell scripts for fetching data and updating guardrails
```

## Contributing

This is a personal tool. You can fork it.

## Publish the action

1. Make the repo public (needed for the Marketplace).
2. Commit `action.yml` and the files it needs.
3. Create a version tag and release:
   - `git tag -a v1 -m "v1"`
   - `git push origin v1`
   - `gh release create v1 --title "v1" --notes ""`
4. In the GitHub Marketplace, list the action (optional).

Use a major tag like `@v1` or a pinned release like `@v1.1`. Move the tag when you cut a new release.
