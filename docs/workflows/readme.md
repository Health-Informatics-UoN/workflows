# Workflow Reference

Documentation for each reusable workflow in this library. These pages cover inputs, outputs, secrets, and usage snippets for individual workflows — use them when you know which workflow you want and need to wire it up.

If you're starting from scratch and want a complete working pipeline, see the [samples](../samples/readme.md) instead.

## Workflows

| File | What it does |
|---|---|
| [semantic-release.md](semantic-release.md) | Runs semantic-release to create a GitHub release from conventional commits. Outputs whether a release was created and the tag — used to gate downstream jobs. |
| [publish-container.md](publish-container.md) | Builds and pushes a multi-arch container image tagged with SHA, timestamp, and `edge`. For dev/edge builds on every push — not stable releases. |
| [semver-container.md](semver-container.md) | Promotes an existing edge/SHA-tagged image to semver tags (`x.y.z`, `x.y`, `x`). Run this after `semantic-release` confirms a release was created. |
| [dependency-review.md](dependency-review.md) | Scans dependency changes in pull requests for known vulnerabilities and licence issues. |
| [pr-title.md](pr-title.md) | Validates that pull request titles follow conventional commit format — required if you're using semantic-release to drive versioning. |
| [publish-pypi.md](publish-pypi.md) | Builds and publishes a Python package to PyPI using OIDC trusted publishing. **Currently broken** — reusable workflows cannot obtain the OIDC token PyPI requires. Inline the publish step instead (see the [PyPI sample](../samples/release.pypi.md)). |
| [dependabot.md](dependabot.md) | How to configure Dependabot in your repo so workflow version references are kept up to date automatically when this library releases a new version. |
