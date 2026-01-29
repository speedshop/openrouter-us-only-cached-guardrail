# OpenRouter US-Only Cached Guardrail

This GitHub Action keeps an OpenRouter guardrail up to date. It runs daily and limits API requests to US-based providers with prompt caching.

## Why Use This

It's nice to keep up with all of the latest and most interesting models, but you want to do so in a cost-effective and safe way. This action helps you do that.

OpenRouter lets you route requests to many AI providers. A guardrail restricts which providers and models your API key can use. This tool builds a guardrail that:

- Only allows US-based providers (for data residency)
- Only allows models with prompt caching (for cost savings)
- Excludes OpenAI, Google and Anthropic (use their APIs directly)

The guardrail updates daily. New providers and models are added when they appear in the OpenRouter API.

## Setup

1. Fork or clone this repository
2. Add your provisioning key as a repository secret:
   - Go to **Settings > Secrets > Actions**
   - Create `OPENROUTER_PROVISIONING_KEY`
   - Get the key from https://openrouter.ai/settings/keys
3. (Optional) Customize the guardrail name:
   - Go to **Settings > Secrets and variables > Actions**
   - Add a variable named `OPENROUTER_GUARDRAIL_NAME`
4. Run the workflow from the **Actions** tab

This action **does not** associate any keys with your Guardrail. You need to do that yourself.

The workflow runs daily at 6am UTC. You can also trigger it by hand.

## Local Use

Run the scripts locally to test or debug:

```bash
./scripts/fetch-providers.sh
./scripts/fetch-cached-models.sh

export OPENROUTER_PROVISIONING_KEY="your-key-here"
./scripts/update-guardrail.sh
```

## Configuration

The guardrail uses these settings:

| Setting | Value |
|---------|-------|
| Name | US Cached Models Only (override with `OPENROUTER_GUARDRAIL_NAME`) |
| Providers | US-based only (no OpenAI, no Anthropic) |
| Models | Must support prompt caching |

To change these rules, edit the scripts in `scripts/`.

## Directory Structure

```
.github/workflows/   GitHub Actions workflow
scripts/             Shell scripts for fetching data and updating guardrails
```

## Contributing

This is a personal tool. Feel free to fork it for your own use.
