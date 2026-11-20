# Claude PR Review

Reusable workflow that reviews a pull request with Claude Code. Claude runs read-only: it can read the checked-out code, but has no shell and no GitHub token.

It reviews when a pull request is opened, gets new commits or is marked ready for review. To request a review at any other time, including on a draft, add the `claude-review` label; it is removed when the review finishes.

Each run posts its findings as one review, on lines in the diff, and a summary comment at the bottom of the pull request, replacing the previous summary.

How the action works, its security restrictions and its tests: see the action's [README](../../.github/actions/claude-review/README.md).

## Good to know

- Pull requests from forks and Dependabot are skipped: they don't get secrets.
- Pull requests over `max-lines` are skipped, with one comment saying so.
- The diff, and files Claude reads, are sent to Anthropic's API. Check this is allowed for your code.
- Claude also applies your repository's `REVIEW.md` or `CLAUDE.md`, which win over the [general standards](../../.github/actions/claude-review/prompt/standards.md).
- The workflow runs `claude -p` with an API key, which the monthly API credits of Claude Max, Ultra and Team plans cover; they don't cover `anthropics/claude-code-action`. See [Monthly API credits](https://support.claude.com/en/articles/17154008).

## Inputs

| Input       | Default             | Description |
|-------------|---------------------|-------------|
| `model`     | `claude-opus-5-5`   | Claude model. `claude-sonnet-5-5` costs about half as much. |
| `max-lines` | `2000`              | Skip pull requests with more changed lines (additions + deletions). Lockfiles count. |
| `max-turns` | `25`                | Maximum Claude turns per review. Raise it with `max-lines`: running out of turns fails the review. |
| `effort`    | `high`              | `low`, `medium`, `high`, `xhigh` or `max`. Higher finds more issues per review, and costs more. |
| `label`     | `claude-review`     | Label that requests a review. |

All inputs are optional.

## Secrets

- `ANTHROPIC_API_KEY`: Claude Console API key, as a repository or organisation secret. Pass it explicitly, as below, not with `secrets: inherit`, so Claude Code gets only this secret.

## Usage

```yaml
name: Claude PR Review

on:
  pull_request:
    # labeled: adding the claude-review label requests a review.
    types: [opened, synchronize, ready_for_review, labeled]

permissions: {}

jobs:
  claude:
    uses: health-informatics-uon/workflows/.github/workflows/claude-review.yml@<version>
    permissions:
      contents: read
      pull-requests: write
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Replace `<version>` with a release tag that includes this workflow (see [pinning](dependabot.md#pinning-strategy)). Do not use `@main`: it changes without review, and this workflow gets your API key.

For on-demand reviews, create the label (`gh label create claude-review`); adding labels needs triage access. Without it, or without `labeled` in the trigger, pull requests are still reviewed automatically.
