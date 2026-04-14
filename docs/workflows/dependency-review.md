# Dependency Review

Reusable workflow that runs [Dependency Review](https://github.com/actions/dependency-review-action) on pull requests. It checks dependency changes (e.g. in `package.json`, `package-lock.json`, `Pipfile`, `go.sum`) for known vulnerabilities and license issues.

## Inputs

None.

## Secrets

- `GITHUB_TOKEN` — Pass with `secrets: inherit` so the action can read the repo and comment on the PR.

## Usage

In your repo, add a workflow that runs on pull requests:

```yaml
name: Dependency Review

on:
  pull_request:

jobs:
  dependency-review:
    uses: health-informatics-uon/workflows/.github/workflows/dependency-review.yml@main
    secrets: inherit
```

Replace `@main` with the branch where this reusable workflow is defined.
