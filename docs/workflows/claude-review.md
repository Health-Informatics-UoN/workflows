# Claude PR Review

Reusable workflow that reviews a pull request with Claude Code and posts the findings as inline comments, plus one summary comment. Claude runs read-only: it can read the checked-out code but has no shell and no GitHub token.

It reviews when a pull request is opened, gets new commits or is marked ready for review. To request a review at any other time, including on a draft, add the `claude-review` label. The label is removed when the review finishes, so it can be added again.

Each run:

- marks the findings from earlier runs that nobody has replied to as **superseded**, with a note at the top saying which review replaced them. The workflow's token isn't allowed to resolve review threads, so people resolve them. A thread with a reply is left alone;
- posts its findings as one review, each on a line or range of lines in the diff;
- posts a new summary comment at the bottom of the pull request, and deletes the previous one. The summary includes any findings that can't be attached to a line in the diff.

The review logic lives in a composite action, [`.github/actions/claude-review`](../../.github/actions/claude-review/). The workflow calls it with `$/`, which resolves to this repository at the same commit as the workflow, so the action always matches the version you pinned. The action's [README](../../.github/actions/claude-review/README.md) explains how it works, its security restrictions and its tests, for anyone changing it.

## Disagreeing with a finding

Reply to the finding's thread to say why, then resolve it (or leave it open to discuss). Later reviews of the pull request are given these replies and won't raise the finding again, unless the code changes in a way your reply doesn't cover.

Only replies from people with access to the repository (owners, organisation members and collaborators) are passed to Claude. Anyone can comment on a public pull request, so other replies could carry instructions meant to mislead the review.

> **Note:** Pull requests from forks and from Dependabot are skipped, because they don't get secrets. Drafts are skipped unless the `claude-review` label is added.

> **Note:** Pull requests with more changed lines than `max-lines` aren't reviewed. Claude comments once to say so.

> **Note:** The pull request's diff, and any files Claude reads for context, are sent to Anthropic's Claude API. Check this is allowed for your repository's code before enabling the review.

> **Note:** The review runs `claude -p` rather than `anthropics/claude-code-action`. The monthly API credits included with Claude Max, Ultra and Team plans cover `claude -p` run with an API key, but not the GitHub Action. Enterprise plans don't get these credits. See [Monthly API credits](https://support.claude.com/en/articles/17154008).

## Review standards

Claude reviews against the [general standards](../../.github/actions/claude-review/prompt/standards.md). If your repository has a `REVIEW.md` or `CLAUDE.md`, Claude applies those too, and they win where they conflict.

## Inputs

| Input       | Required | Default             | Description                                                              |
|-------------|----------|---------------------|--------------------------------------------------------------------------|
| `model`     | No       | `claude-opus-5-5`   | Claude model to use. Opus is the most capable; `claude-sonnet-5-5` costs about half as much per review. |
| `max-lines` | No       | `2000`              | Skip pull requests with more changed lines (additions + deletions) than this. Generated files such as lockfiles count too. |
| `max-turns` | No       | `25`                | Maximum number of Claude turns per review. Limits cost. Claude spends turns reading files, so if you raise `max-lines`, raise this too; running out of turns fails the review. |
| `label`     | No       | `claude-review`     | Label that requests a review when added to a pull request.               |

## Secrets

- `ANTHROPIC_API_KEY` — Claude Console API key. Pass it explicitly, not with `secrets: inherit`. This workflow runs Claude Code, so passing the key explicitly gives it only that secret, not all of your repository's secrets.

## Usage

In your repo, add a workflow that runs on pull requests:

```yaml
name: Claude PR Review

on:
  pull_request:
    # labeled: adding the claude-review label requests a review.
    types: [opened, synchronize, ready_for_review, labeled]

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

Before the first run, add `ANTHROPIC_API_KEY` as a repository or organisation secret.

To let people request a review with the label, also create the `claude-review` label in the repository (Issues → Labels → New label, or `gh label create claude-review`). This is optional: without the label, pull requests are still reviewed automatically. Adding a label needs triage access or higher, so not everyone who can comment can request a review. If you don't want on-demand reviews, leave `labeled` out of the trigger types.
