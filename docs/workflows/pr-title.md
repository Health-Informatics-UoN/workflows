# PR Title Check

Reusable workflow that validates pull request titles using [action-semantic-pull-request](https://github.com/amannn/action-semantic-pull-request). Titles must follow a conventional-commit style (e.g. `feat: add login`, `fix: resolve crash`).

## Inputs

None.

## Secrets

- `GITHUB_TOKEN` — Pass with `secrets: inherit` so the action can read the PR and post status checks.

## Usage

In your repo, add a workflow that runs on pull requests:

```yaml
name: PR Title Check

on:
  pull_request:

jobs:
  pr-title:
    uses: health-informatics-uon/workflows/.github/workflows/pr-title.yml@main
    secrets: inherit
```

Replace `@main` with the branch where this reusable workflow is defined.
