# Sample Workflows

Ready-to-copy workflow files and supporting configuration for complete release pipelines. Each sample wires several reusable workflows together into an end-to-end pipeline — copy it into your repo and fill in the blanks rather than composing the pieces yourself.

If you want to understand what an individual workflow does, see the [workflow reference](../workflows/readme.md) instead.

## Samples

| File | What it gives you |
|---|---|
| [release.container.md](release.container.md) | A full container release pipeline: semantic-release determines the version, a multi-arch container image is built and pushed as `edge`, then promoted to semver tags if a release was created. For repos that ship a Docker image. |
| [release.pypi.md](release.pypi.md) | A full Python package release pipeline: semantic-release determines the version, then the package is built and published to PyPI using OIDC trusted publishing (no API tokens). For Python packages shipping to PyPI. |
