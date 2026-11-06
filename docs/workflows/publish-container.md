# Publish Container Image

Reusable workflow that builds and pushes a multi-architecture container image to a registry (e.g. `ghcr.io`).

On a push to a branch, it tags the image with:

- the current commit SHA (short `sha-<hash>` and full)
- a timestamp (`YYYYMMDDHHmmssZ`)
- `edge` (representing the latest main/dev build) — default branch only

On a pull request, it tags the image with:

- `pr-<number>` (the latest build of the PR)
- `sha-<hash>` of the PR's own commit (not the merge commit GitHub builds)

Pull request builds never move `edge`, and they never get the full SHA tag, so `semver-container` can't release them.

This is intended for releasing dev/edge images and pull request test images, not stable semver releases.

## Inputs

| Input              | Required | Default                         | Description                                           |
|--------------------|----------|---------------------------------|-------------------------------------------------------|
| `image-name`       | Yes      | —                               | Image name, e.g. `my-app` or `services/api`.         |
| `image-description`| No       | `''`                            | Description used in OCI annotations.                 |
| `registry`         | No       | `'ghcr.io'`                     | Registry host.                                       |
| `repo-owner`       | No       | calling repo owner             | Owner/namespace (e.g. `Health-Informatics-UoN`).     |
| `context`          | No       | `'.'`                           | Docker build context.                                |
| `dockerfile`       | No       | `'Dockerfile'`                  | Path to `Dockerfile` relative to repo root/context.  |
| `platforms`        | No       | `'linux/amd64,linux/arm64'`     | Target platforms for the image.                      |
| `build-args`       | No       | `''`                            | Build-time variables, newline-separated `KEY=VALUE` pairs, passed through to `docker/build-push-action` (e.g. `VERSION=1.2.3`). |
| `publish-pr-images` | No     | `false`                         | Publish images for pull requests from branches in your repo. Off by default, so pull requests only check the image builds. Forks and Dependabot never push. |

## Secrets

- `GITHUB_TOKEN` — Pass with `secrets: inherit` so the workflow can log in to the registry and push images.

## Usage

In your repo, add a workflow that runs on push to your main/dev branch:

```yaml
name: Publish Dev Container

on:
  push:
    branches:
      - main

jobs:
  publish-container:
    uses: health-informatics-uon/workflows/.github/workflows/publish-container.yml@main
    with:
      image-name: my-service
      image-description: 'My service edge build'
      registry: ghcr.io
      # repo-owner: Health-Informatics-UoN   # optional override
      context: .
      dockerfile: Dockerfile
      platforms: linux/amd64,linux/arm64
      build-args: |
        VERSION=1.2.3
    secrets: inherit
```

`build-args` is optional — omit it if your Dockerfile doesn't declare any `ARG`s you need to pass through.

This will publish images like:

- `ghcr.io/<owner>/my-service:<sha>`
- `ghcr.io/<owner>/my-service:<timestamp>`
- `ghcr.io/<owner>/my-service:edge`

## Pull request builds

To build every pull request, add a workflow that runs on `pull_request`. By default this only checks the image builds. To also publish images for pull requests from branches in your repo, set `publish-pr-images: true`. Pull requests from forks and Dependabot get a read-only token, so for those the workflow only checks the image builds, whatever is set:

```yaml
name: Check Container Builds

on:
  pull_request:

# A new push to the PR cancels the build of the previous one
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  packages: write

jobs:
  build:
    uses: health-informatics-uon/workflows/.github/workflows/publish-container.yml@main
    with:
      image-name: my-service
      image-description: 'My service pull request build'
      publish-pr-images: true
    secrets: inherit
```

With `publish-pr-images: true`, this will publish images like:

- `ghcr.io/<owner>/my-service:pr-123`
- `ghcr.io/<owner>/my-service:sha-abc1234`

Without `publish-pr-images: true`, pull requests only check the image builds and nothing is published. In that case `packages: write` isn't needed.

Use the `pull_request` trigger, not `pull_request_target`. `pull_request_target` runs with a write token even for pull requests from forks, and builds the base branch rather than the pull request, so the workflow fails straight away if it is called from it.
