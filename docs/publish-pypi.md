# Publish Python Package to PyPI

Reusable workflow that builds a Python package and publishes it to [PyPI](https://pypi.org) using OIDC trusted publishing (no API token required).

The workflow has two jobs:

1. **Build** — runs `python -m build` and uploads the resulting `dist/` as a workflow artifact
2. **Publish** — downloads the artifact and publishes to PyPI via `pypa/gh-action-pypi-publish`

## Inputs

| Input                | Required | Default  | Description                                                                          |
|----------------------|----------|----------|--------------------------------------------------------------------------------------|
| `package-name`       | Yes      | —        | PyPI package name, used to construct the PyPI URL (e.g. `my-package`).              |
| `python-version`     | No       | `'3.x'`  | Python version to build with.                                                        |
| `environment-name`   | No       | `'pypi'` | GitHub environment to use for the publish job.                                       |
| `working-directory`  | No       | `'.'`    | Directory containing the package, relative to repo root. Useful for monorepos.       |
| `use-uv`             | No       | `false`  | Use `uv build` instead of `pip + build`. Faster builds; uv manages Python itself.   |

## PyPI Trusted Publishing (OIDC)

This workflow uses [PyPI trusted publishing](https://docs.pypi.org/trusted-publishers/) rather than an API token. Before using this workflow you must configure a trusted publisher on PyPI for your package:

- **Publisher:** GitHub Actions
- **Repository:** your repo (e.g. `Health-Informatics-UoN/my-repo`)
- **Workflow filename:** the caller workflow filename (e.g. `release.yml`)
- **Environment:** matches the `environment-name` input (default: `pypi`)

## Usage

Typically chained after `semantic-release` so publishing only happens on a new release:

```yaml
jobs:
  release:
    uses: health-informatics-uon/workflows/.github/workflows/semantic-release.yml@main
    secrets: inherit

  publish-pypi:
    needs: release
    if: needs.release.outputs.release-created == 'true'
    uses: health-informatics-uon/workflows/.github/workflows/publish-pypi.yml@main
    with:
      package-name: my-package
```

### With uv

```yaml
    with:
      package-name: my-package
      use-uv: true
```

### Monorepo

```yaml
    with:
      package-name: my-package
      working-directory: packages/my-package
```
