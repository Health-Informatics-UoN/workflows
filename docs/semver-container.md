# Semver Container Release

Reusable workflow that:

- tags an existing container image with semver tags (`x.y.z`, `x`, `x.y`) based on the git tag
- verifies that a corresponding container image (tagged with the commit SHA) already exists
- creates a GitHub Release for the tag

Use this when you already have an \"edge\" or commit-SHA container image (for example from the `publish-container` workflow) and you want to promote it to a semver release.

## Inputs

| Input               | Required | Default                            | Description                                                      |
|---------------------|----------|------------------------------------|------------------------------------------------------------------|
| `image-name`        | Yes      | —                                  | Image name, e.g. `my-app` or `services/api`.                     |
| `registry`          | No       | `'ghcr.io'`                        | Registry host.                                                   |
| `release-name-prefix` | No     | `''`                               | String prefixed to the Release title (e.g. project name + space).|
| `container-link`    | No       | `''`                               | URL to the container package page, shown in the Release body.    |

## Secrets

- `GITHUB_TOKEN` — Pass with `secrets: inherit` so the workflow can read tags, create releases, and push tags in the container registry.

## Usage

This workflow is designed to run **from a tag ref**, e.g. when a tag like `v1.2.3` is created. In your repo, create a workflow such as:

```yaml
name: Semver Container Release

on:
  push:
    tags:
      - v*

jobs:
  semver-container:
    uses: health-informatics-uon/workflows/.github/workflows/semver-container.yml@main
    with:
      image-name: my-service
      registry: ghcr.io
      release-name-prefix: 'My Service '               # note trailing space
      container-link: 'https://github.com/OWNER/REPO/pkgs/container/my-service'
    secrets: inherit
```

This will:

- check that an image `ghcr.io/<owner>/my-service:<sha>` exists
- push additional tags like `1.2.3`, `1`, and `1.2` to that image

