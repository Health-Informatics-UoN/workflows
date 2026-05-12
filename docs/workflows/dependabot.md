# Keeping Workflows Up to Date with Dependabot

When you reference workflows from this repository, GitHub will not automatically update those references when new versions are released. Adding a Dependabot configuration to your repo causes Dependabot to open pull requests that bump the workflow versions for you.

## Configuration

Add `.github/dependabot.yml` to your repository:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    commit-message:
      prefix: "chore(dependencies): "
```

This scans all workflows under `.github/workflows/` weekly and opens a PR whenever a newer version tag is available for any referenced action or reusable workflow, including those from this repository.

## Pinning strategy

### This repository: semver tags

Referencing `@main` means your workflow always uses the latest commit on `main`, without any pull request or review. Pinning to a semver tag (e.g. `@1.2.3` or `@1`) gives you:

- A stable, reviewed reference that only changes when you choose to update
- A clear diff and changelog when Dependabot opens an update PR
- The ability to test updates before merging

```yaml
jobs:
  release:
    uses: health-informatics-uon/workflows/.github/workflows/semantic-release.yml@1
    secrets: inherit
```

Semver tags here are safe to trust because this repository uses semantic-release with conventional commits — tags are immutable, meaningful, and only created by the release pipeline.

### Third-party actions: commit hashes

For actions from outside this organisation, pin to a full commit SHA rather than a tag. Tag names on external repositories can be moved or deleted by the owner, which means a tag reference can silently start pointing at different code. A commit SHA is immutable.

```yaml
steps:
  - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
```

Dependabot still opens update PRs for hash-pinned actions — it updates the SHA and adds a comment with the corresponding tag, so you keep the benefits of reviewed updates without the supply-chain risk.
