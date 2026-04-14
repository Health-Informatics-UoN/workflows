# Release Container Workflow Sample

This sample workflow demonstrates a complete release pipeline that combines semantic versioning, container publishing, and automated tagging. It's designed to be copied into your project's `.github/workflows/` directory and customised for your specific needs.

## Overview

The workflow performs the following steps:

1. **Semantic Release**: Analyses commits since the last release to determine if a new version should be created, and if so, generates a new Github release with an automatically generated changelog.
2. **Container Publishing**: Builds and pushes a container image with an `edge` tag (we avoid latest, so this is a pre-release build)
3. **Semver Tagging**: If a release was created, promotes the edge image to semantic version tags (e.g., `1.2.3`, `1.2`, `1`)

## Prerequisites

- Your repository must follow [conventional commit](https://conventionalcommits.org/) format
- We recommend `samples/check.pr-title.yaml` to enforce this on pull requests
- Your repository settings should only allow squash merges, and use the PR title as the commit message for commit messages to be correctly parsed by semantic-release
- You need a `samples/release.config.js` in your repository root to configure semantic-release
- You need a `Dockerfile` in your repository root (or update the `dockerfile` parameter)

## Workflow Jobs

### semantic-release

Uses the [`semantic-release.yml`](../semantic-release.md) reusable workflow to:

- Install and run semantic-release
- Create GitHub releases with automatically generated changelogs
- Output `release-created` (boolean) and `release-tag` (version string)

### publish-container

Uses the [`publish-container.yml`](../publish-container.md) reusable workflow to:

- Build a multi-architecture container image
- Tag it with SHA, timestamp, and "edge"
- Push to the specified container registry

**Parameters:**
- `image-name`: Name of your container image
- `image-description`: Description for the image
- `registry`: Container registry (e.g., `ghcr.io`, `docker.io`)
- `context`: Build context path (usually `.`)
- `dockerfile`: Path to Dockerfile
- `platforms`: Target architectures (comma-separated)

### semver-container

Uses the [`semver-container.yml`](../semver-container.md) reusable workflow to:

- Promote the edge image to semantic version tags
- Only runs if `semantic-release` created a new release

**Parameters:**
- `image-name`: Must match the `publish-container` job
- `registry`: Must match the `publish-container` job
- `tag`: Release tag from semantic-release (do not modify)

### Version Pinning

For production use, pin to specific versions:

```yaml
uses: health-informatics-uon/workflows/.github/workflows/semantic-release.yml@v1.3.0
```

Check the [releases](https://github.com/health-informatics-uon/workflows/releases) for available versions.

## Usage
   
1. Copy `samples/release.container.yaml` to your repository's `.github/workflows/release.yaml`
2. Copy `samples/release.config.js` to your repository root and customise it for your repository
3. Update the workflow parameters in `release.yaml` (image name, etc.)
4. Ensure your repository follows the prerequisites (conventional commits, squash merges, etc.)
