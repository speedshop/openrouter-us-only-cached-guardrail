# OpenRouter US-Only Cached Guardrail

A GitHub Action that automatically updates an OpenRouter guardrail daily with US-only providers and cached models.

## What It Does

- Fetches US-based providers from OpenRouter (excluding OpenAI and Anthropic)
- Fetches models that support prompt caching
- Creates or updates a guardrail named "US Cached Models Only"
- Runs daily at 6am UTC via GitHub Actions

## Setup

1. Clone this repository
2. Add your `OPENROUTER_PROVISIONING_KEY` as a repository secret
   - Get your key from https://openrouter.ai/settings/keys
3. Enable GitHub Actions
4. Trigger the workflow manually or wait for the daily run

## Manual Execution

```bash
# Fetch US providers
./scripts/fetch-providers.sh

# Fetch cached models
./scripts/fetch-cached-models.sh

# Update guardrail (requires OPENROUTER_PROVISIONING_KEY env var)
./scripts/update-guardrail.sh
```

## Guardrail Configuration

- **Name**: US Cached Models Only
- **Providers**: All US-based providers except OpenAI and Anthropic
- **Models**: All models with caching support (excluding anthropic/*, openai/gpt-5*, openai/o*)
