# Claude PR Review

Reusable workflow that reviews a pull request with Claude Code and posts the findings as inline comments, plus one summary comment. Claude runs read-only: it can read the checked-out code but has no shell and no GitHub token.

The review logic lives in a composite action, [`.github/actions/claude-review`](../../.github/actions/claude-review/). The workflow calls it with `$/`, which resolves to this repository at the same commit as the workflow, so the action always matches the version you pinned.

> **Note:** Pull requests from forks, from Dependabot and drafts are skipped; forks and Dependabot don't get secrets.

> **Note:** Pull requests with more changed lines than `max-lines` aren't reviewed. Claude comments once to say so.

> **Note:** The review runs `claude -p` rather than `anthropics/claude-code-action`. The API credits included with Claude Team and Max plans cover the CLI run with an API key, but not the action.

## Review standards

Claude reviews against the [general standards](../../.github/actions/claude-review/standards.md). If your repository has a `REVIEW.md` or `CLAUDE.md`, Claude applies those too, and they win where they conflict.

## Inputs

| Input       | Required | Default             | Description                                                              |
|-------------|----------|---------------------|--------------------------------------------------------------------------|
| `model`     | No       | `claude-sonnet-5-5` | Claude model to use.                                                     |
| `max-lines` | No       | `1000`              | Skip pull requests with more changed lines (additions + deletions) than this. |

## Secrets

- `ANTHROPIC_API_KEY` — Claude Console API key. Pass it explicitly, not with `secrets: inherit`.

## Usage

In your repo, add a workflow that runs on pull requests:

```yaml
name: Claude PR Review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review]

permissions: {}

jobs:
  claude:
    uses: health-informatics-uon/workflows/.github/workflows/claude-review.yml@main
    permissions:
      contents: read
      pull-requests: write
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Add `ANTHROPIC_API_KEY` as a repository or organisation secret first.
