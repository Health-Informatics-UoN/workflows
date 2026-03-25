# Semantic Release

Reusable workflow that runs [semantic-release](https://github.com/semantic-release/semantic-release) to determine the next version from commits and publish a GitHub release. Expects a [semantic-release config](https://github.com/semantic-release/semantic-release/blob/master/docs/usage/configuration.md) (e.g. `release.config.js` or `.releaserc`) in the calling repository.

## Inputs

| Input          | Required | Default | Description                |
|----------------|----------|---------|----------------------------|
| `node-version` | No       | `'24'`  | Node.js version to use.    |

## Outputs

| Output            | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `release-created` | `'true'` if a new release was created, `'false'` if not.                 |
| `release-tag`     | The tag created by semantic-release (e.g. `1.2.3`). Empty string if no release was created. |

Use these to conditionally run downstream jobs (e.g. re-tag a container, publish to PyPI) only when a release actually happened:

```yaml
jobs:
  release:
    uses: health-informatics-uon/workflows/.github/workflows/semantic-release.yml@main
    secrets: inherit

  publish:
    needs: release
    if: needs.release.outputs.release-created == 'true'
    uses: health-informatics-uon/workflows/.github/workflows/semver-container.yml@main
    with:
      image-name: my-app
      tag: ${{ needs.release.outputs.release-tag }}
    secrets: inherit
```

> **Note:** If the workflow itself errors, `release-created` will be an empty string rather than `'false'`. Always use `== 'true'` rather than `!= 'false'` in conditions.

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
    "repositoryUrl": "https://github.com/Health-Informatics-UoN/[REPO_NAME].git",
    plugins: [
      '@semantic-release/commit-analyzer',
      '@semantic-release/release-notes-generator',
      '@semantic-release/exec',
      '@semantic-release/github',
    ],
    "initialVersion": "0.0.1"
};
```

## Python Configuration

In `pyproject.toml` use `hatch-vcs` for a dynamic version.

```toml copy
dynamic = ["version"]

[build-system]
requires = ["hatchling", "hatch-vcs"]
build-backend = "hatchling.build"

[tool.hatch.version]
source = "vcs"

```

## C# Configuration

TODO

## Javascript Configuration

TODO
