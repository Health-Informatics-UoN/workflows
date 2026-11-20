# Gateway publish action

A composite action that builds HDR UK Health Data Research Gateway metadata from a LinkML schema plus hand-written catalogue fields, validates it, and publishes it to the Gateway. This page is for people changing it. To use it, see [the workflow docs](../../../docs/workflows/gateway-publish.md): most repositories should call the reusable workflows, not this action.

## How it works

The action is a Python package, `gateway-publish`, with a CLI. [`action.yml`](action.yml) installs it with uv (from [`uv.lock`](uv.lock)) and [`scripts/run.sh`](scripts/run.sh) runs it with `validate` or `push`, copying the output to the job summary. The credentials reach the CLI as environment variables, never as arguments.

| Module | What it does |
|---|---|
| [`build.py`](src/gateway_publish/build.py) | Finds the dataset files and builds the payload: `structuralMetadata` from the LinkML schema (one table per `tree_root` class, one column per slot, enum values as column values), the rest from `gateway/metadata.yaml`, plus the fields the Gateway overwrites anyway. |
| [`validate.py`](src/gateway_publish/validate.py) | Validates against the bundled HDRUK schemas (`schemas/HDRUK/<version>/schema.json`, from [HDRUK/schemata-2](https://github.com/HDRUK/schemata-2)), reporting the most specific error inside nested `anyOf`s. |
| [`traser.py`](src/gateway_publish/traser.py) | Sends the payload to TRASER `/translate` exactly as the Gateway does, so translation errors show up before publishing. |
| [`client.py`](src/gateway_publish/client.py) | The Gateway API client, with hints for the known error messages. |
| [`config.py`](src/gateway_publish/config.py) | Credentials and base URL from the environment. It refuses to send credentials to unknown hosts. |
| [`cli.py`](src/gateway_publish/cli.py) | `build`, `validate`, `create`, `push`, plus `get`, `list`, `update` and `delete` for manual use. |

## Using the CLI locally

```bash
cd .github/actions/gateway-publish
uv run gateway-publish --help
uv run gateway-publish validate --dataset ~/src/nuh-data-sact --traser
uv run gateway-publish build ~/src/nuh-data-sact --version 1.0.0 -o payload.json
uv run gateway-publish push ~/src/nuh-data-sact --version 1.0.0 --dry-run
```

Commands that call the Gateway need `GATEWAY_APP_ID` and `GATEWAY_CLIENT_ID` in the environment. The team comes from `gateway.yaml`, or `GATEWAY_TEAM_ID` for the commands that don't take a dataset. Keep credentials in a gitignored `.env` file and use `uv run --env-file .env ...`.

## The Gateway API

HDR UK's [integration docs](https://hdruk.github.io/gateway-2-integrations-testing/) are out of date: they describe the retired `/api/v1/integrations/datasets` endpoints, which now return 410. This action uses the team dataset API instead, which accepts the Private App headers (`x-application-id`, `x-client-id`). Most of what follows comes from reading the [gateway-api source](https://github.com/HDRUK/gateway-api) and was then confirmed on the live Gateway in November 2026.

| Action | Request |
|---|---|
| Create | `POST /v2/teams/{team}/datasets?input_schema=HDRUK&input_version=4.1.0` |
| Update (adds a version) | `PUT /v3/teams/{team}/datasets/{id}` |
| Get | `GET /v2/teams/{team}/datasets/{id}[?schema_model=HDRUK&schema_version=4.1.0]` |
| List | `GET /v2/teams/{team}/datasets/status/{active,draft,archived}?title=` |
| Delete | `DELETE /v2/teams/{team}/datasets/{id}` (needs the app's delete permission) |

- **Use v3 to update.** `PUT /v2/...` overwrites the latest version in place. `PUT /v3/...` (not in Swagger) adds a version and stores only a JSON Patch, so after a v3 update the plain GET returns `"metadata": []`. Ask for `schema_model`/`schema_version` to get the full document.
- **Body:** `{"metadata": {"metadata": <doc>, "schemaModel": "HDRUK", "schemaVersion": "4.1.0"}, "create_origin": "API", "status": "DRAFT"|"ACTIVE"}`. Always send `status`: without it an update sets the status to null. The envelope declares the input schema on update; on create, only the query parameters reach TRASER.
- **The Gateway overwrites** `identifier` (with its own `pid`), `issued`, `modified`, `revisions` and `summary.dataCustodian` (the owning team). It stores the metadata as GWDM 2.2 and translates it back on GET.
- **Drafts skip validation.** The Gateway only calls TRASER with validation for `ACTIVE` datasets, so the action always runs TRASER itself.
- **TRASER is stricter than the HDRUK schema.** For example, `provenance.temporal.endDate: CONTINUOUS` is valid HDRUK 4.1.0 but fails translation to GWDM 2.2.
- **Unknown IDs:** GET returns 404, but update and delete probably return 500.

## Tests

The tests use mocked HTTP for the Gateway and TRASER, so they need no credentials. [`action-tests.yml`](../../workflows/action-tests.yml) runs them on PRs that change `.github/actions/`. To run them locally:

```bash
cd .github/actions/gateway-publish
uv run pytest
```

- `tests/test_build.py` has a golden-file test: the payload built from `tests/fixtures/demographics/` must match `tests/fixtures/demographics.golden.json`. After an intended change, regenerate it with `UPDATE_GOLDEN=1 uv run pytest tests/test_build.py` and review the diff.
- `tests/test_live.py` creates, updates and deletes a draft on a real Gateway. It is skipped unless `GATEWAY_LIVE_TESTS=1`, and needs credentials with delete permission.

## Changing the action

- **New HDRUK schema version:** add `src/gateway_publish/schemas/HDRUK/<version>/schema.json` from schemata-2, change `SCHEMA_VERSION` in `build.py`, and check that TRASER accepts the payloads.
- **GWDM version:** `GWDM_VERSION` in `traser.py` must match what the live Gateway stores (`gwdm_version` on a dataset version).
- **Dependencies:** change `pyproject.toml`, run `uv lock`, and commit `uv.lock`. Dependabot proposes updates monthly.
