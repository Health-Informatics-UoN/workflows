# HDR UK Gateway Publish and Validate

Two reusable workflows that publish a dataset's metadata to the [HDR UK Health Data Research Gateway](https://healthdatagateway.org) from a LinkML repo:

- `gateway-validate.yml` builds the metadata and validates it with HDR UK's TRASER service, as the Gateway does. Run it on pull requests. It needs no secrets.
- `gateway-publish.yml` validates, then sends the metadata to the Gateway as a new version of an existing dataset. Run it after `semantic-release` creates a release.

Both run the [gateway-publish action](../../.github/actions/gateway-publish/README.md). It combines:

- the **LinkML schema**, which gives the tables, columns and permitted values; and
- **`gateway/metadata.yaml`**, the catalogue fields (title, abstract, coverage, access and so on), written by hand in the [HDRUK 4.1.0 schema](https://github.com/HDRUK/schemata-2/tree/master/hdr_schemata/models/HDRUK/4.1.0)'s shape.

## Set up a dataset repo

1. **Add `gateway/metadata.yaml`.** Use field names and nesting from the HDRUK 4.1.0 schema. Don't set `identifier`, `version`, `issued`, `modified`, `revisions`, `structuralMetadata` or `summary.dataCustodian`: the tool fills them, and the Gateway overwrites most of them. Leave out `provenance.temporal.endDate` for an ongoing dataset: the Gateway rejects `CONTINUOUS`. Any value starting `TODO` stops the build.
2. **Add `gateway/gateway.yaml`:**

   ```yaml
   team_id: 74                       # the Gateway team that owns the Private App
   team_name: Nottingham University Hospitals - NHS Trust
   status: DRAFT                     # or ACTIVE; every release publishes with this status
   dataset_id: null                  # written by the one-off create (step 5)
   pid: null
   ```

3. **Add the PR check** ([sample](../../samples/check.gateway.yaml)), and check that it passes.
4. **Create the `gateway` environment** (Settings → Environments). Add required reviewers, and limit deployments to protected branches or tags. Add the Private App's credentials as environment secrets `GATEWAY_APP_ID` and `GATEWAY_CLIENT_ID` (from the app's Authentication tab on the Gateway). Create the environment before the first release: GitHub creates a missing environment automatically, without any protection.
5. **Create the dataset on the Gateway, once,** from a local checkout. This writes `dataset_id` and `pid` into `gateway/gateway.yaml`. Commit that change.

   ```sh
   export GATEWAY_APP_ID=... GATEWAY_CLIENT_ID=...   # don't put these in shell history or files in the repo
   uv run --project <workflows checkout>/.github/actions/gateway-publish \
     gateway-publish create . --version 0.0.0
   ```

6. **Add the publish job** to the release workflow ([sample](../../samples/release.gateway.yaml)).

The workflows never create datasets and never write to the repository. If `gateway.yaml` has no `dataset_id`, publishing fails with instructions.

## `gateway-validate.yml`

| Input | Required | Default | Description |
|---|---|---|---|
| `dataset-dir` | No | `.` | Directory holding `gateway/`. |
| `schema` | No | the only `*.yaml` in `dataset-dir`, else in `dataset-dir/schemas` | LinkML schema. |
| `traser` | No | `true` | Validate with HDR UK's TRASER service, as the Gateway does: against HDRUK 4.1.0, then translated to GWDM. This is the only validation. |
| `traser-url` | No | HDR UK's dev TRASER | TRASER base URL. |

## `gateway-publish.yml`

| Input | Required | Default | Description |
|---|---|---|---|
| `version` | Yes | — | Metadata version, `major.minor.patch` (a leading `v` is removed). Pass `release-tag` from `semantic-release`. |
| `ref` | No | `version` | Git ref to publish from. |
| `dataset-dir` | No | `.` | Directory holding `gateway/`. |
| `schema` | No | as above | LinkML schema. |
| `status` | No | `status` in `gateway.yaml`, else `DRAFT` | `DRAFT` or `ACTIVE`. |
| `dry-run` | No | `false` | Print the request instead of sending it. Needs no credentials. |
| `environment` | No | `gateway` | GitHub environment for the publish job. |
| `base-url` | No | `https://api.healthdatagateway.org/api` | Gateway API base URL. Credentials are only sent to known Gateway hosts. |
| `team-id` | No | `team_id` in `gateway.yaml` | Gateway team. If set, it must match `gateway.yaml`. |
| `traser` | No | `true` | As above. |
| `traser-url` | No | HDR UK's dev TRASER | As above. |

| Secret | Required | Description |
|---|---|---|
| `GATEWAY_APP_ID` | For a real publish | The Private App's App ID. |
| `GATEWAY_CLIENT_ID` | For a real publish | The Private App's Client ID. |

With `secrets: inherit`, the publish job uses the `gateway` environment's secrets of these names. To use repository secrets instead, pass them by name.

The workflow has two jobs:

1. **validate**: builds and validates the release, without secrets. A broken release fails here, before anyone is asked to approve.
2. **publish**: waits for the environment's reviewers, then validates again, sends a new version (`PUT /v3/teams/{team}/datasets/{id}`), reads the dataset back, and fails unless the version went up and the title matches. One publish runs at a time per repository. Reads are retried on server errors; the update is not, because a retry could add a second version. The output is in the job summary.

## Things to know

- **The repository is the source of truth.** Each release replaces the whole record and sets its status from `gateway.yaml`, so edits made in the Gateway's web UI are lost, and a dataset archived there becomes active again at the next release.
- **Every release adds a Gateway version**, even if the metadata didn't change. The Gateway labels them `1.0.0`, `2.0.0`, ...; our release version is kept in the metadata's `version` field.
- **Drafts skip the Gateway's validation.** The workflows always check with TRASER, so a draft that publishes should also pass when switched to `ACTIVE`.
- **To make a dataset public**, change `status` in `gateway.yaml` to `ACTIVE` in a PR. The next release publishes it.
- The Gateway API this uses is not in HDR UK's published documentation. If a publish fails unexpectedly, see the action's README.
