# HDR UK Gateway

Reusable workflow that publishes a dataset's metadata to the [HDR UK Health Data Research Gateway](https://healthdatagateway.org) from a LinkML repo. It always validates; with `publish: true` it also sends the metadata as a new version of the dataset.

The metadata combines the LinkML schema (tables, columns and permitted values) with `gateway/metadata.yaml`, the catalogue fields written by hand in the [HDRUK 4.1.0 schema](https://github.com/HDRUK/schemata-2/tree/master/hdr_schemata/models/HDRUK/4.1.0)'s shape. Validation is done by HDR UK's TRASER service, the way the Gateway does it.

## Set up a dataset repo

1. **`gateway/metadata.yaml`:** HDRUK 4.1.0 field names and nesting. Don't set `identifier`, `version`, `issued`, `modified`, `revisions`, `structuralMetadata` or `summary.dataCustodian`; they're generated. Leave out `provenance.temporal.endDate` for an ongoing dataset (the Gateway rejects `CONTINUOUS`). Values starting `TODO` fail the build.
2. **`gateway/gateway.yaml`:**

   ```yaml
   team_id: 74
   team_name: Nottingham University Hospitals - NHS Trust
   status: DRAFT        # or ACTIVE; every release publishes with this status
   dataset_id: null     # written by create (step 4)
   pid: null
   ```

3. **A `gateway` environment** (Settings → Environments) with required reviewers, and the Private App's credentials as environment secrets `GATEWAY_APP_ID` and `GATEWAY_CLIENT_ID`. Create it before the first release: GitHub creates a missing environment without protection.
4. **Create the dataset once**, from a local checkout, then commit `gateway/gateway.yaml`:

   ```sh
   A=<workflows checkout>/.github/actions/gateway-publish
   GATEWAY_APP_ID=... GATEWAY_CLIENT_ID=... \
     uv run --frozen --project "$A" python "$A/gateway_publish.py" create . --version 0.0.0 \
       --gateway-url https://api.healthdatagateway.org/api \
       --traser-url https://hdr-gateway-traser-dev-qmnkcg5qjq-ew.a.run.app
   ```

5. **Call the workflow** on PRs and after releases:

   ```yaml
   # .github/workflows/check.gateway.yml
   on: pull_request
   jobs:
     gateway:
       uses: health-informatics-uon/workflows/.github/workflows/gateway.yml@<tag>
       permissions:
         contents: read
   ```

   ```yaml
   # in the release workflow, after semantic-release
     gateway:
       needs: release
       if: needs.release.outputs.release-created == 'true'
       uses: health-informatics-uon/workflows/.github/workflows/gateway.yml@<tag>
       permissions:
         contents: read
       with:
         publish: true
         version: ${{ needs.release.outputs.release-tag }}
       secrets: inherit
   ```

## Inputs

| Input | Default | Description |
|---|---|---|
| `publish` | `false` | Publish after validating. |
| `version` | — | Metadata version, `major.minor.patch`; a leading `v` is removed. Pass the release tag; required to publish. |
| `dataset-dir` | `.` | Directory holding `gateway/`. |
| `schema` | the only `*.yaml` in `dataset-dir`, else in `dataset-dir/schemas` | LinkML schema. |
| `status` | `status` in `gateway.yaml` | `DRAFT` or `ACTIVE`. |
| `dry-run` | `false` | Print the publish request instead of sending it. |
| `environment` | `gateway` | GitHub environment for the publish job. |
| `base-url` | `https://api.healthdatagateway.org/api` | Gateway API base URL. |
| `traser` | `true` | Validate with TRASER; `false` skips validation. |
| `traser-url` | `https://hdr-gateway-traser-dev-qmnkcg5qjq-ew.a.run.app` (HDR UK's dev instance) | TRASER base URL. |

Secrets `GATEWAY_APP_ID` and `GATEWAY_CLIENT_ID` are needed only to publish. With `secrets: inherit`, the publish job uses the environment's secrets; you can pass repository secrets by name instead.

## Things to know

- **The repository is the only way to change the dataset.** The Gateway doesn't allow editing a dataset managed by an integration in its web UI, including its status. Every change to the metadata or the status goes through a PR and a release.
- **Every release adds a Gateway version**, even if nothing changed. After publishing, the job reads the dataset back and fails unless the version went up and the title matches. A failed update isn't retried, because a retry could add a second version.
- **To make a dataset public, or take it back to draft**, change `status` in `gateway.yaml` in a PR; the next release applies it.
