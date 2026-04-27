# Semver Container Release

Reusable workflow that:

- tags an existing container image with semver tags (`x.y.z`, `x`, `x.y`) based on a provided release tag, and optionally `latest`
- verifies that a corresponding container image (tagged with the commit SHA) already exists

Use this when you already have an "edge" or commit-SHA container image (for example from the `publish-container` workflow) and you want to promote it to a semver release.

> **Note:** The `x`, `x.y`, and `latest` floating tags are only applied for stable releases. Pre-release versions (e.g. `1.0.0-beta.1`) receive only the full version tag.

## Inputs

| Input        | Required | Default     | Description                                          |
|--------------|----------|-------------|------------------------------------------------------|
| `image-name` | Yes      | —           | Image name, e.g. `my-app` or `services/api`.         |
| `registry`   | No       | `'ghcr.io'` | Registry host.                                       |
| `tag`        | Yes      | —           | The release tag to derive semver from (e.g. `1.2.3` or `v1.2.3`). Typically passed from the `release-tag` output of the `semantic-release` workflow. |
| `tag-latest` | No       | `false`     | Also push a `latest` tag. Only applied to stable releases, not pre-releases. |

## Secrets

- `GITHUB_TOKEN` — Pass with `secrets: inherit` so the workflow can push tags in the container registry.

## Usage

This workflow is designed to run as part of a release process, chained after `semantic-release`:

```yaml
jobs:
  release:
    uses: health-informatics-uon/workflows/.github/workflows/semantic-release.yml@main
    secrets: inherit

  semver-container:
    needs: release
    if: needs.release.outputs.release-created == 'true'
    uses: health-informatics-uon/workflows/.github/workflows/semver-container.yml@main
    with:
      image-name: my-service
      tag: ${{ needs.release.outputs.release-tag }}
    secrets: inherit
```

This will:

- check that an image `ghcr.io/<owner>/my-service:<sha>` exists
- push additional tags like `1.2.3`, `1`, and `1.2` to that image (or just `1.2.3` for pre-releases)

To also push a `latest` tag on stable releases, set `tag-latest: true`:

```yaml
  semver-container:
    needs: release
    if: needs.release.outputs.release-created == 'true'
    uses: health-informatics-uon/workflows/.github/workflows/semver-container.yml@main
    with:
      image-name: my-service
      tag: ${{ needs.release.outputs.release-tag }}
      tag-latest: true
    secrets: inherit
```
