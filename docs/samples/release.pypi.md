# Release PyPI Workflow Sample

This sample workflow demonstrates a complete release pipeline for Python packages, combining semantic versioning with publishing to [PyPI](https://pypi.org) using trusted publishing (OIDC — no API tokens required).

Like the container release sample, the goal is a drop-in model where developers communicate their intent through PR titles and the workflow takes care of the rest: generating release notes, creating GitHub releases, and publishing the package.

## Overview

The workflow performs the following steps:

1. **Semantic Release**: Analyses commits since the last release to determine if a new version should be created, and if so, generates a new GitHub release with an automatically generated changelog.
2. **Publish to PyPI**: If a release was created, builds the Python package and publishes it to PyPI using OIDC trusted publishing.

## Why the publish step is inline

PyPI's [trusted publishing](https://docs.pypi.org/trusted-publishers/) uses OIDC tokens, which GitHub only issues to jobs running directly in a non-reusable workflow. Reusable workflows (called via `uses:`) are not granted these tokens.

This means the `publish-pypi` job **must** remain as a direct job in your non-reusable `release.yml` — it cannot be extracted into a reusable workflow. This is an intentional constraint from PyPI/GitHub, not a limitation of this library. See the [upstream issue](https://github.com/pypa/gh-action-pypi-publish/issues/166) for background.

The `semantic-release` step can still be a reusable workflow call, and the `publish-pypi` job simply depends on its output.

## Prerequisites

- Your repository must follow [conventional commit](https://conventionalcommits.org/) format
- We recommend `samples/check.pr-title.yaml` to enforce this on pull requests
- Your repository settings should only allow squash merges, using the PR title as the commit message so semantic-release can parse it correctly
- You need a `release.config.js` in your repository root — copy from `samples/release.config.js` and update `repositoryUrl`
- Your package must be configured to derive its version from git tags (see [Python setup](#python-setup) below)
- You must configure a PyPI trusted publisher for your package (see [PyPI setup](#pypi-trusted-publisher-setup) below)

## PyPI Trusted Publisher Setup

Before running this workflow, configure a trusted publisher on PyPI for your package:

1. Go to your package on PyPI → **Manage** → **Publishing**
2. Add a new trusted publisher with:
   - **Publisher:** GitHub Actions
   - **Owner:** your GitHub organisation or username
   - **Repository:** your repository name
   - **Workflow filename:** the filename you save this sample as (e.g. `release.yml`)
   - **Environment:** `pypi` (matches the `environment.name` in the workflow)

This replaces API tokens entirely. The workflow authenticates to PyPI automatically via the OIDC token GitHub issues at runtime.

## Python Setup

Your `pyproject.toml` should derive its version dynamically from the git tag created by semantic-release. Follow `samples/pyproject.toml` using `hatch-vcs`:

```toml
dynamic = ["version"]

[build-system]
requires = ["hatchling", "hatch-vcs"]
build-backend = "hatchling.build"

[tool.hatch.version]
source = "vcs"
```

This means `python -m build` will automatically stamp the package with the correct version from the git tag — no manual version management needed.

## Workflow Jobs

### release

Uses the [`semantic-release.yml`](../workflows/semantic-release.md) reusable workflow to:

- Install and run semantic-release
- Create a GitHub release with an automatically generated changelog
- Output `release-created` (`'true'`/`'false'`) and `release-tag` (version string, e.g. `1.2.3`)

### publish-pypi

A direct (non-reusable) job that:

- Only runs when `release-created == 'true'`
- Builds the Python package with `python -m build`
- Publishes to PyPI using `pypa/gh-action-pypi-publish` with OIDC trusted publishing

**Parameters to customise:**

- `environment.url`: Replace `<PACKAGE_NAME>` with your PyPI package name

## Usage

1. Copy `samples/release.pypi.yaml` to `.github/workflows/release.yml` in your repository
2. Copy `samples/release.config.js` to your repository root and update `repositoryUrl`
3. Replace `<PACKAGE_NAME>` with your PyPI package name
4. Configure your `pyproject.toml` to use `hatch-vcs` (see [Python setup](#python-setup))
5. Configure a trusted publisher on PyPI (see [PyPI trusted publisher setup](#pypi-trusted-publisher-setup))
6. Ensure your repository follows the prerequisites (conventional commits, squash merges)

### Version pinning

The sample references `@1.4.0`. For production use, pin to a specific version and update deliberately:

```yaml
uses: health-informatics-uon/workflows/.github/workflows/semantic-release.yml@1.4.0
```

Check [releases](https://github.com/health-informatics-uon/workflows/releases) for the latest version.
