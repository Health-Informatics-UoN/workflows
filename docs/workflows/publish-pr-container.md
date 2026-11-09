# Publish PR Container Image

Reusable workflow that builds a multi-architecture container image for a pull request and pushes it to a registry (e.g. `ghcr.io`). It tags the image with:

- `pr-<number>` (the latest build of the pull request)
- the pull request's commit SHA (`sha-<commit>`)
- the git tree hash of the code that was built (`tree-<hash>`)

Use this on `pull_request` so a change can be tested from its image before it is merged. For images built on merge to main, use the `publish-container` workflow.

> **Note:** Pull request images are never tagged `edge`, `latest`, a semver version or the full commit SHA, so they can't be promoted by the `semver-container` workflow.

> **Note:** Pull requests from forks and from Dependabot only check that the image builds; nothing is pushed. Fork pull requests get a read-only `GITHUB_TOKEN`, so they can't push.

## Inputs

| Input              | Required | Default                         | Description                                           |
|--------------------|----------|---------------------------------|-------------------------------------------------------|
| `image-name`       | Yes      | —                               | Image name, e.g. `my-app` or `services/api`.         |
| `image-description`| No       | `''`                            | Description used in OCI annotations.                 |
| `registry`         | No       | `'ghcr.io'`                     | Registry host.                                       |
| `repo-owner`       | No       | calling repo owner             | Owner/namespace (e.g. `Health-Informatics-UoN`).     |
| `context`          | No       | `'.'`                           | Docker build context.                                |
| `dockerfile`       | No       | `'Dockerfile'`                  | Path to `Dockerfile` relative to repo root/context.  |
| `platforms`        | No       | `'linux/amd64,linux/arm64'`     | Target platforms for the image. Use the same platforms as your release build. |
| `build-args`       | No       | `''`                            | Build-time variables, newline-separated `KEY=VALUE` pairs, passed through to `docker/build-push-action` (e.g. `VERSION=1.2.3`). |
| `cache-from`       | No       | `'type=gha'`                    | Passed to `cache-from` in `docker/build-push-action`. |
| `cache-to`         | No       | `'type=gha,mode=max'`           | Passed to `cache-to` in `docker/build-push-action`.  |
| `publish`          | No       | `true`                          | Push the image. Set `false` to only check it builds. |

## Secrets

- `GITHUB_TOKEN` — Pass with `secrets: inherit` so the workflow can log in to the registry and push images.

## Usage

In your repo, add a workflow that runs on pull requests:

```yaml
name: Check Container Builds

on:
  pull_request:

jobs:
  build:
    permissions:
      contents: read
      packages: write
    uses: health-informatics-uon/workflows/.github/workflows/publish-pr-container.yml@main
    with:
      image-name: my-service
      image-description: 'My service pull request build'
      platforms: linux/amd64,linux/arm64
    secrets: inherit
```

Use the `pull_request` trigger, not `pull_request_target`. `pull_request_target` runs with a write token even for pull requests from forks, and builds the base branch rather than the pull request.

This will publish images like:

- `ghcr.io/<owner>/my-service:pr-123`
- `ghcr.io/<owner>/my-service:sha-abc1234`
- `ghcr.io/<owner>/my-service:tree-<hash>`

The `tree-<hash>` tag identifies the exact code that was built. A squash merge gives the merged code a new commit SHA, but the same tree hash if `main` hasn't moved on, so a later workflow can find the image built from identical code (see [#71](https://github.com/Health-Informatics-UoN/workflows/issues/71)).

To only check that pull requests build, without pushing anything, set `publish: false`. `packages: write` isn't needed then.

Pull request images are not cleaned up automatically. Set a retention policy on the package, or add a cleanup job.
