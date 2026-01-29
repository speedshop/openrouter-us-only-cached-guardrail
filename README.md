# OpenRouter US-Only Cached Guardrail

This GitHub Action keeps an OpenRouter guardrail up to date. It runs daily and limits API requests to US-based providers with prompt caching.

## Why Use This

It's nice to keep up with all of the latest and most interesting models, but you want to do so in a cost-effective and safe way. This action helps you do that.

OpenRouter lets you route requests to many AI providers. A guardrail restricts which providers and models your API key can use. This tool builds a guardrail that:

- Only allows US-based providers (for data residency)
- Only allows models with prompt caching (for cost savings)
- Excludes OpenAI, Google and Anthropic (use their APIs directly)

The guardrail updates daily. New providers and models are added when they appear in the OpenRouter API.

## Use as a GitHub Action

Add a workflow to any repo you want to run the guardrail update from:

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
        uses: <owner>/<repo>@v1
        with:
          provisioning_key: ${{ secrets.OPENROUTER_PROVISIONING_KEY }}
          guardrail_name: ${{ vars.OPENROUTER_GUARDRAIL_NAME }}
          upload_inputs: "true"
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `provisioning_key` | Yes | — | OpenRouter provisioning key |
| `guardrail_name` | No | `US Cached Models Only` | Guardrail name override |
| `upload_inputs` | No | `false` | Upload `us-providers.json` and `cached-models.json` as artifacts |

### Required secrets/variables

1. Add your provisioning key as a repository secret:
   - Go to **Settings > Secrets and variables > Actions**
   - Create `OPENROUTER_PROVISIONING_KEY`
   - Get the key from https://openrouter.ai/settings/keys
2. (Optional) Customize the guardrail name:
   - Go to **Settings > Secrets and variables > Actions**
   - Add a variable named `OPENROUTER_GUARDRAIL_NAME`

This action **does not** associate any keys with your Guardrail. You need to do that yourself.

## Local Use

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
action.yml           Reusable GitHub Action (composite)
scripts/             Shell scripts for fetching data and updating guardrails
```

## Contributing

This is a personal tool. Feel free to fork it for your own use.

## Publishing the Action

1. Make sure the repository is public (required for the Marketplace).
2. Commit `action.yml` and any supporting files.
3. Create a version tag and release:
   - `git tag -a v1 -m "v1"`
   - `git push origin v1`
   - `gh release create v1 --title "v1" --notes ""`
4. In the GitHub Marketplace, list the action (optional but recommended).

Consumers should pin to a major version tag like `@v1` and you can update that tag as you release new compatible versions.
