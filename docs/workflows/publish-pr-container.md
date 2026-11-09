# Publish Pull Request Container Image

Reusable workflow that builds a multi-architecture container image for a pull request and publishes it to a registry (e.g. `ghcr.io`), so the pull request can be tested before it is merged.

It is designed to run on `pull_request` only, and fails straight away if called from any other trigger. For images built on merge to main, use [publish-container](publish-container.md).

It tags the image with:

- `pr-<number>` — the latest build of the pull request
- `sha-<commit>` — the pull request's own commit, not the temporary merge commit GitHub builds
- `tree-<hash>` — the git tree hash of the code that was built. A squash merge gives the merged code a new commit SHA, but the same tree hash if `main` hasn't moved on, so this lets a later workflow find the image built from identical code ([#71](https://github.com/Health-Informatics-UoN/workflows/issues/71))

It never tags `edge`, `latest`, semver versions or the full commit SHA, so pull request images can't be released by [semver-container](semver-container.md).

## Forks and Dependabot

Pull requests from forks and from Dependabot get a read-only `GITHUB_TOKEN`, so they can't publish. For those the workflow detects this, skips the registry login, and only checks the image builds.

Use the `pull_request` trigger, not `pull_request_target`. `pull_request_target` runs with a write token even for pull requests from forks, and builds the base branch rather than the pull request.

## Inputs

| Input               | Required | Default                     | Description                                                                 |
|---------------------|----------|-----------------------------|-----------------------------------------------------------------------------|
| `image-name`        | Yes      | —                           | Image name, e.g. `my-app` or `services/api`.                                |
| `image-description` | No       | `''`                        | Description used in OCI annotations.                                       |
| `registry`          | No       | `'ghcr.io'`                 | Registry host.                                                              |
| `repo-owner`        | No       | calling repo owner          | Owner/namespace (e.g. `Health-Informatics-UoN`).                            |
| `context`           | No       | `'.'`                       | Docker build context.                                                       |
| `dockerfile`        | No       | `'Dockerfile'`              | Path to `Dockerfile` relative to repo root/context.                         |
| `platforms`         | No       | `'linux/amd64,linux/arm64'` | Target platforms for the image. Use the same platforms as your release build. |
| `build-args`        | No       | `''`                        | Build-time variables, newline-separated `KEY=VALUE` pairs.                  |
| `cache-from`        | No       | `'type=gha'`                | Passed to `cache-from` in `docker/build-push-action`.                       |
| `cache-to`          | No       | `'type=gha,mode=max'`       | Passed to `cache-to` in `docker/build-push-action`.                         |
| `publish`           | No       | `true`                      | Publish the image. Set `false` to only check it builds. Forks and Dependabot never publish. |

## Secrets

- `GITHUB_TOKEN` — Pass with `secrets: inherit` so the workflow can log in to the registry and push images.

## Usage

In your repo, add a workflow that runs on `pull_request`:

```yaml
name: Check Container Builds

on:
  pull_request:

# A new push to the PR cancels the build of the previous one
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  build:
    permissions:
      contents: read
      packages: write
    uses: health-informatics-uon/workflows/.github/workflows/publish-pr-container.yml@main
    with:
      image-name: my-service
      image-description: 'My service pull request build'
    secrets: inherit
```

This will publish images like:

- `ghcr.io/<owner>/my-service:pr-123`
- `ghcr.io/<owner>/my-service:sha-abc1234`
- `ghcr.io/<owner>/my-service:tree-<hash>`

To only check pull requests build, without publishing anything, add `publish: false`. `packages: write` isn't needed then.

## Things to know

- Pull request images are not cleaned up automatically. Set a retention policy on the package, or add a cleanup job.
- The image is built from the merge of the pull request into its base branch, as GitHub checks it out. The `sha-` tag and `org.opencontainers.image.revision` label use the pull request's own commit, so they match what you see in the pull request.
