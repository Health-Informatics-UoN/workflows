# Publish Container Image

Reusable workflow that builds and pushes a multi-architecture container image to a registry (e.g. `ghcr.io`). It tags the image with:

- the current commit SHA
- a timestamp (`YYYYMMDDHHmmssZ`)
- `edge` (representing the latest main/dev build)

This is intended for releasing dev/edge images, not stable semver releases.

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
    secrets: inherit
```

This will publish images like:

- `ghcr.io/<owner>/my-service:<sha>`
- `ghcr.io/<owner>/my-service:<timestamp>`
- `ghcr.io/<owner>/my-service:edge`

