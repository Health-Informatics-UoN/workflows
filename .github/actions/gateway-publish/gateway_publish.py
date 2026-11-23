"""Publish a dataset's metadata to the HDR UK Health Data Research Gateway.

The payload (HDRUK 4.1.0) is built from a dataset directory:
  <name>.yaml or schemas/<name>.yaml   LinkML schema -> structuralMetadata
  gateway/metadata.yaml                hand-written catalogue fields, in HDRUK 4.1.0 shape
  gateway/gateway.yaml                 team_id, team_name, status, dataset_id, pid

Commands:
  validate DIR             build, then check with TRASER
  create DIR --version V   once per dataset; writes dataset_id and pid to gateway.yaml
  push DIR --version V     validate, PUT a new version, read it back

Gateway API notes (HDR UK's integration docs describe a retired API):
- Auth is a Private App's x-application-id / x-client-id headers, on the team dataset API.
- Create is POST /v2/teams/{team}/datasets. Update is PUT /v3/...: the v2 PUT overwrites
  the latest version instead of adding one.
- The metadata is sent in the envelope the Gateway's own form uses, which declares the
  input schema. Always send status: an update without it sets the status to null.
- The Gateway overwrites identifier, issued, modified, revisions and dataCustodian; we fill
  them only so the payload validates.
- The Gateway runs TRASER (HDRUK -> GWDM translation, with validation) on ACTIVE datasets
  only, so we always run it ourselves first. It is stricter than the HDRUK schema, e.g. it
  rejects provenance.temporal.endDate: CONTINUOUS.
"""

import argparse
import json
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

import httpx
import yaml
from linkml_runtime.utils.schemaview import SchemaView

SCHEMA = ("HDRUK", "4.1.0")
GWDM_VERSION = "2.2"  # what the live Gateway stores
STATUSES = ("DRAFT", "ACTIVE")
# Filled by build; metadata.yaml must not set them.
GENERATED = ("identifier", "version", "issued", "modified", "revisions", "structuralMetadata")
TIMEOUT = httpx.Timeout(60.0, connect=10.0)
transport = None  # tests replace this with an httpx.MockTransport


class Error(Exception):
    pass


class _Loader(yaml.SafeLoader):
    """Keeps unquoted dates (startDate: 2020-01-01) as strings, as HDRUK expects."""


_Loader.yaml_implicit_resolvers = {
    k: [r for r in v if r[0] != "tag:yaml.org,2002:timestamp"]
    for k, v in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def load_yaml(path: Path) -> dict:
    if not path.is_file():
        raise Error(f"Missing {path}")
    return yaml.load(path.read_text(), Loader=_Loader) or {}


def find_schema(root: Path) -> Path:
    for folder in (root, root / "schemas"):
        found = sorted(folder.glob("*.yaml"))
        if len(found) == 1:
            return found[0]
        if found:
            raise Error(f"More than one *.yaml in {folder}; pass --schema")
    raise Error(f"No LinkML schema (*.yaml) in {root} or {root / 'schemas'}; pass --schema")


def structural_metadata(schema: Path) -> dict:
    """One table per tree_root class, one column per slot; enums carry their values."""
    sv = SchemaView(str(schema))
    tables = []
    for cls in (c for c in sv.all_classes().values() if c.tree_root):
        columns = []
        for name in sv.class_slots(cls.name):
            slot = sv.induced_slot(name, cls.name)
            enum = sv.get_enum(slot.range, strict=False) if slot.range else None
            column = {
                "name": slot.name,
                "dataType": "string" if enum else slot.range or "string",
                "description": (slot.description or "").strip() or None,  # HDRUK rejects ""
                # Our LinkML schemas mark sensitive slots with a `sensitivity` annotation.
                "sensitive": "sensitivity" in slot.annotations,
            }
            if enum:
                column["values"] = [
                    {"name": k, "description": (v.description or "").strip() or None}
                    for k, v in enum.permissible_values.items()
                ]
            columns.append(column)
        tables.append({"name": cls.name, "description": (cls.description or "").strip() or None, "columns": columns})
    if not tables:
        raise Error(f"{schema}: no tree_root class")
    return {"tables": tables}


def todos(value, path=""):
    if isinstance(value, dict):
        return [p for k, v in value.items() for p in todos(v, f"{path}/{k}")]
    if isinstance(value, list):
        return [p for i, v in enumerate(value) for p in todos(v, f"{path}/{i}")]
    return [path] if isinstance(value, str) and value.strip().startswith("TODO") else []


def build(root: Path, schema: Path | None, version: str, now: datetime | None = None) -> tuple[dict, dict]:
    """Return (payload, gateway.yaml contents)."""
    metadata = load_yaml(root / "gateway" / "metadata.yaml")
    gateway = load_yaml(root / "gateway" / "gateway.yaml")
    for key in ("team_id", "team_name"):
        if not gateway.get(key):
            raise Error(f"gateway.yaml: '{key}' is required")
    if gateway.get("status") not in (None, *STATUSES):
        raise Error("gateway.yaml: status must be DRAFT or ACTIVE")
    version = version.removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise Error(f"Version must be major.minor.patch, got {version!r}")
    if found := todos(metadata):
        raise Error(f"metadata.yaml still has TODOs at: {', '.join(found)}")
    clashes = [f for f in GENERATED if f in metadata]
    if "dataCustodian" in metadata.get("summary", {}):
        clashes.append("summary/dataCustodian")
    if clashes:
        raise Error(f"metadata.yaml must not set fields that are generated: {', '.join(clashes)}")

    stamp = (now or datetime.now(UTC)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    summary = metadata.get("summary", {})
    return {
        # The Gateway sets its own pid as the identifier; null is valid before create.
        "identifier": gateway.get("pid"),
        "version": version,
        "revisions": [],
        "issued": stamp,
        "modified": stamp,
        **metadata,
        "summary": {**summary, "dataCustodian": {
            "identifier": str(gateway["team_id"]), "name": gateway["team_name"], "contactPoint": summary.get("contactPoint"),
        }},
        "structuralMetadata": structural_metadata(schema or find_schema(root)),
    }, gateway


def traser_check(payload: dict, traser_url: str) -> None:
    """Make the call the Gateway makes for ACTIVE datasets; raise with TRASER's errors."""
    try:
        with httpx.Client(base_url=traser_url, timeout=120, transport=transport) as client:
            response = client.post("/translate", params={
                "input_schema": SCHEMA[0], "input_version": SCHEMA[1], "output_schema": "GWDM",
                "output_version": GWDM_VERSION, "validate_input": "1", "validate_output": "1",
            }, json={"metadata": payload, "extra": {
                # The Gateway adds this block for GWDM's required fields; the values don't
                # affect validation.
                "id": "placeholder", "pid": "placeholder", "datasetType": "Health and disease",
                "publisherId": "placeholder", "publisherName": "placeholder",
            }})
    except httpx.HTTPError as e:
        raise Error(f"Could not reach TRASER at {traser_url}: {e}") from None
    if response.is_success:
        return
    try:
        body = response.json()
    except ValueError:
        body = {"message": response.text[:300]}
    details = body.get("details")
    if isinstance(details, dict):
        details = details.get("validationErrors")
    lines = [f"  {d.get('instancePath') or '/'}: {d.get('message')} {d.get('params') or ''}" for d in details or []]
    raise Error("\n".join([f"TRASER rejected the metadata (HTTP {response.status_code}): {body.get('message')}", *lines]))


def gateway_client(gateway_url: str) -> httpx.Client:
    missing = [n for n in ("GATEWAY_APP_ID", "GATEWAY_CLIENT_ID") if not os.environ.get(n)]
    if missing:
        raise Error(f"Missing environment variable(s): {', '.join(missing)}")
    return httpx.Client(
        base_url=gateway_url,
        headers={"x-application-id": os.environ["GATEWAY_APP_ID"], "x-client-id": os.environ["GATEWAY_CLIENT_ID"]},
        timeout=TIMEOUT,
        transport=transport,
    )


def call(client: httpx.Client, method: str, path: str, **kwargs) -> dict:
    try:
        response = client.request(method, path, **kwargs)
    except httpx.HTTPError as e:
        message = f"Gateway {method} {path} failed: {e}"
        if method != "GET":
            message += ". The change may still have been applied: check the dataset on the Gateway before re-running."
        raise Error(message) from None
    if not response.is_success:
        try:
            message = response.json().get("message")
        except ValueError:
            message = response.text[:300]
        raise Error(f"Gateway {method} {path}: HTTP {response.status_code}: {message}")
    return response.json()


def latest(client: httpx.Client, team: int, dataset_id: int) -> tuple[int, str | None]:
    """(version number, title) of the dataset's latest version."""
    versions = call(client, "GET", f"/v2/teams/{team}/datasets/{dataset_id}")["data"]["versions"]
    newest = max(versions, key=lambda v: v["version"])
    return newest["version"], newest.get("title")


def body(payload: dict, status: str) -> dict:
    envelope = {"metadata": payload, "schemaModel": SCHEMA[0], "schemaVersion": SCHEMA[1]}
    return {"metadata": envelope, "create_origin": "API", "status": status}


def record_created(path: Path, dataset_id: int, pid: str | None) -> None:
    """Write dataset_id and pid into gateway.yaml, keeping its comments."""
    text = path.read_text()
    for key, value in (("dataset_id", dataset_id), ("pid", pid)):
        line = f"{key}: {'null' if value is None else value}"
        text, n = re.subn(rf"^{key}:.*$", line, text, count=1, flags=re.MULTILINE)
        if not n:
            text = text.rstrip("\n") + f"\n{line}\n"
    path.write_text(text)


def validate(args: argparse.Namespace) -> tuple[dict, dict]:
    """Build the payload and check it with TRASER. Returns (payload, gateway.yaml)."""
    payload, gateway = build(args.dataset, args.schema, args.version or "0.0.0")
    if args.skip_traser:
        print("Built; TRASER check skipped")
    else:
        traser_check(payload, args.traser_url)
        print(f"Valid {SCHEMA[0]} {SCHEMA[1]}; translates to GWDM {GWDM_VERSION} (TRASER)")
    return payload, gateway


def create(args: argparse.Namespace) -> None:
    """Create the dataset on the Gateway, once, and record its ID in gateway.yaml."""
    payload, gateway = validate(args)
    if gateway.get("dataset_id"):
        raise Error(f"gateway.yaml already has dataset_id {gateway['dataset_id']}; use push")
    status = args.status or gateway.get("status") or "DRAFT"
    datasets = f"/v2/teams/{gateway['team_id']}/datasets"
    gateway_yaml = args.dataset / "gateway" / "gateway.yaml"
    with gateway_client(args.gateway_url) as client:
        dataset_id = call(client, "POST", datasets, json=body(payload, status),
                          params={"input_schema": SCHEMA[0], "input_version": SCHEMA[1]})["data"]
        record_created(gateway_yaml, dataset_id, None)  # save the ID first, so it is never lost
        pid = call(client, "GET", f"{datasets}/{dataset_id}")["data"].get("pid")
    record_created(gateway_yaml, dataset_id, pid)
    print(f"Created {status} dataset {dataset_id}; commit gateway/gateway.yaml")


def push(args: argparse.Namespace) -> None:
    """Send the payload as a new version of the dataset, then check it arrived."""
    payload, gateway = validate(args)
    dataset_id = gateway.get("dataset_id")
    if not dataset_id:
        raise Error("gateway.yaml has no dataset_id: run `create` once and commit gateway.yaml")
    status = args.status or gateway.get("status") or "DRAFT"
    team = gateway["team_id"]
    if args.dry_run:
        print(f"DRY RUN: PUT {args.gateway_url}/v3/teams/{team}/datasets/{dataset_id}")
        print(json.dumps(body(payload, status), indent=2, ensure_ascii=False))
        return
    with gateway_client(args.gateway_url) as client:
        before, _ = latest(client, team, dataset_id)
        # Not retried: a retry could add a second version.
        call(client, "PUT", f"/v3/teams/{team}/datasets/{dataset_id}", json=body(payload, status))
        after, title = latest(client, team, dataset_id)
    print(f"Dataset {dataset_id}: version {before} -> {after}, status {status}")
    if after <= before or title != payload["summary"]["title"]:
        raise Error(f"Read-back check failed: version {after}, title {title!r}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("validate", "create", "push"))
    parser.add_argument("dataset", type=Path, help="dataset directory (holds gateway/)")
    parser.add_argument("--schema", type=Path, help="LinkML schema (default: the only *.yaml in DIR, else DIR/schemas)")
    parser.add_argument("--version", help="metadata version, major.minor.patch; required for create and push")
    parser.add_argument("--status", choices=STATUSES, help="default: gateway.yaml's status, else DRAFT")
    parser.add_argument("--dry-run", action="store_true", help="push: print the request instead of sending it")
    parser.add_argument("--gateway-url", required=True, help="Gateway API base URL, e.g. https://api.healthdatagateway.org/api")
    parser.add_argument("--traser-url", required=True, help="TRASER base URL")
    parser.add_argument("--skip-traser", action="store_true")
    args = parser.parse_args(argv)
    if args.command != "validate" and not args.version:
        parser.error(f"--version is required for {args.command}")

    try:
        {"validate": validate, "create": create, "push": push}[args.command](args)
    except Error as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
