# Claude PR Review

Reusable workflow that reviews a pull request with Claude Code. Claude runs read-only: it can read the checked-out code, but has no shell and no GitHub token.

It reviews when a pull request is opened, gets new commits or is marked ready for review. To request a review at any other time, including on a draft, add the `claude-review` label to the open pull request; it is removed when the review finishes. The label does nothing on a closed pull request.

Each run posts its findings as one review, on lines in the diff, and a summary comment at the bottom of the pull request, replacing the previous summary. Findings from earlier runs that nobody replied to are marked **superseded**; resolve them when checked.

How the action works, its security restrictions and its tests: see the action's [README](../../.github/actions/claude-review/README.md).

## Set up a repository

1. **Create an API key** in the [Claude Console](https://console.anthropic.com). Use a workspace of its own with a monthly spend limit: the limit caps the cost of a busy month, or of a leaked key.

2. **Add it as a secret** named `ANTHROPIC_API_KEY`: in the repository, Settings → Secrets and variables → Actions → New repository secret. An organisation secret works too, if the repository has access to it.

3. **Add the workflow** as `.github/workflows/check.claude-review.yml`, copied from [the sample](../../samples/check.claude-review.yaml):

   ```yaml
   name: "Claude PR review"

   on:
     pull_request:
       types:
         - opened
         - synchronize
         - ready_for_review
         # Adding the claude-review label requests a review.
         - labeled

   permissions: {}

   jobs:
     claude:
       # Replace <NEW_SHA> and <NEW_VERSION> with a release that includes claude-review.yml.
       uses: health-informatics-uon/workflows/.github/workflows/claude-review.yml@<NEW_SHA> # <NEW_VERSION>
       permissions:
         contents: read
         pull-requests: write
       secrets:
         ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
   ```

   - Replace `<NEW_SHA>` and `<NEW_VERSION>` with a release that includes this workflow (see [pinning](dependabot.md#pinning-strategy)). Don't use `@main`: it changes without review, and this workflow gets your API key.
   - Pass the secret by name, as above, not with `secrets: inherit`, so Claude Code gets only this secret.
   - `pull-requests: write` lets it post comments; `contents: read` stops it pushing.

4. **Create the label** (optional), for reviews on demand, including on drafts:

   ```sh
   gh label create claude-review --description "Request a Claude review"
   ```

   Adding a label needs triage access. Without the label, or without `labeled` in the trigger, pull requests are still reviewed automatically.

5. **Add review rules** (optional): a `REVIEW.md` (or `CLAUDE.md`) at the repository root. Claude applies it, and it wins over the [general standards](../../.github/actions/claude-review/prompt/standards.md).

6. **Keep the version up to date** with Dependabot's `github-actions` updates (see [Dependabot](dependabot.md)).

7. **Check it works:** open a pull request. A `claude / review` check runs and, after a few minutes, a summary comment appears. If the check fails with "ANTHROPIC_API_KEY is empty", the secret is missing or isn't passed under `secrets:`.

If your organisation allows only selected actions, allow the ones the workflow uses: `actions/checkout`, `actions/setup-node` and `astral-sh/setup-uv`.

## Disagreeing with a finding

Reply to the finding to say why, then resolve it or leave it open. Later reviews get your reply and won't raise the finding again, unless the code changes in a way your reply doesn't cover. Only replies from owners, organisation members and collaborators count: anyone can comment on a public pull request.

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
