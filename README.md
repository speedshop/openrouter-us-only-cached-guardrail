# Speedshop OpenRouter Coding Agent Guardrail

Create and update opinionated OpenRouter guardrail for trying new models in coding agents. 

## What This Guardrail Enforces

- **Only models with prompt cache**. Coding agents become unusably expensive without this.
- **Only US-based inference**. Rule of law and security concerns in other jurisdictions.
- **Minimum latency/throughput**. No likes a slow coding agent.
- **No OpenAI, Google or Anthropic**. Don't accidentally pay a bunch of money for stuff you should have bought a Max plan for.

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
      upload_artifacts: "false"
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

If you are curious what this repo allows right now, check the artifacts from
the scheduled workflow in this repo:
[Demo Update OpenRouter Guardrail](https://github.com/speedshop/openrouter-us-only-cached-guardrail/actions/workflows/demo-update-guardrail.yml).
The artifacts include
`available-models.json`, `cached-models.json`, and `us-providers.json`.

To change these rules, edit the scripts in `scripts/`.

## Directory structure

```
.github/workflows/   Reusable GitHub Actions workflow
action.yml           Reusable GitHub Action (composite)
scripts/             Shell scripts for fetching data and updating guardrails
```

## Contributing

This is a personal tool. You can fork it.
