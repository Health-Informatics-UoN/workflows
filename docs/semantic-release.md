# Semantic Release

Reusable workflow that runs [semantic-release](https://github.com/semantic-release/semantic-release) to determine the next version from commits and publish a GitHub release. Expects a [semantic-release config](https://github.com/semantic-release/semantic-release/blob/master/docs/usage/configuration.md) (e.g. `release.config.js` or `.releaserc`) in the calling repository.

## Inputs

| Input           | Required | Default | Description                |
|----------------|----------|---------|----------------------------|
| `node-version` | No       | `'24'`  | Node.js version to use.    |

## Secrets

- `GITHUB_TOKEN` — Pass with `secrets: inherit` (or set explicitly) so the workflow can create releases and comment on PRs/issues.

## Usage

In your repo, add a workflow that runs on push to `main` (or your release branch):

```yaml
name: Release

on:
  push:
    branches:
      - main

jobs:
  release:
    uses: health-informatics-uon/workflows/.github/workflows/semantic-release.yml@main
    with:
      node-version: '24'   # optional
    secrets: inherit
```

Ensure the branch in `@main` matches the branch where this reusable workflow is defined.

`release.config.js`

```json copy
module.exports = {
    "branches": ["main"],
    "tagFormat": "${version}",
    "preset": "angular",
    "repositoryUrl": "https://github.com/Health-Informatics-UoN/nuh-helper.git",
    plugins: [
      '@semantic-release/commit-analyzer',
      '@semantic-release/release-notes-generator',
      '@semantic-release/exec',
      '@semantic-release/github',
    ],
    "initialVersion": "0.0.1"
};
```
