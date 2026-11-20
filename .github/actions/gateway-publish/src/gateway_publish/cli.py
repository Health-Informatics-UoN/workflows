"""Command line interface: gateway-publish <command> ..."""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from gateway_publish.build import SCHEMA_MODEL, SCHEMA_VERSION, BuildError, DatasetDir, build_payload
from gateway_publish.client import STATUSES, GatewayClient, GatewayError, latest_version
from gateway_publish.config import DEFAULT_BASE_URL, ConfigError, GatewayConfig
from gateway_publish.traser import TraserError, traser_errors
from gateway_publish.validate import validation_errors

DECLARED_SCHEMA = (SCHEMA_MODEL, SCHEMA_VERSION)
# Any valid version will do when only checking a dataset directory.
VALIDATE_VERSION = "0.0.0"


class CommandError(Exception):
    pass


def _load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        raise CommandError(f"File not found: {path}") from None
    except json.JSONDecodeError as e:
        raise CommandError(f"{path} is not valid JSON: {e}") from None


def _print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, ensure_ascii=False))


def _client(args: argparse.Namespace, default_team_id: int | None = None) -> GatewayClient:
    """`default_team_id` applies only when neither --team-id nor $GATEWAY_TEAM_ID is set."""
    team_id = args.team_id
    if team_id is None and not os.environ.get("GATEWAY_TEAM_ID"):
        team_id = default_team_id
    return GatewayClient(GatewayConfig.from_env(base_url=args.base_url, team_id=team_id))


def cmd_create(args: argparse.Namespace) -> None:
    if args.dataset:
        _create_dataset(args)
        return
    metadata = _load_json(args.file)
    status = args.status or "DRAFT"
    with _client(args) as client:
        result = client.create(metadata, status=status)
    print(f"Created {status} dataset {result.dataset_id} (version id {result.version_id})")


def cmd_update(args: argparse.Namespace) -> None:
    metadata = _load_json(args.file)
    with _client(args) as client:
        _print_json(client.update(args.id, metadata, status=args.status or "DRAFT"))


def cmd_get(args: argparse.Namespace) -> None:
    with _client(args) as client:
        _print_json(client.get(args.id, args.schema_model, args.schema_version))


def cmd_delete(args: argparse.Namespace) -> None:
    if args.confirm != args.id:
        raise CommandError(f"Refusing to delete: pass --confirm {args.id} to confirm")
    with _client(args) as client:
        _print_json(client.delete(args.id))


def cmd_list(args: argparse.Namespace) -> None:
    with _client(args) as client:
        _print_json(client.list(status=args.status, title=args.title))


def _check(metadata: dict[str, Any], label: str, model: str, version: str, traser: bool) -> None:
    """Validate locally, then optionally with TRASER; exit 1 with readable errors on failure."""
    errors = validation_errors(metadata, version, model)
    if errors:
        print(f"{label} is NOT valid {model} {version}:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"{label} is valid {model} {version}")

    if traser:
        errors = traser_errors(metadata, version, model)
        if errors:
            print(f"{label} failed the TRASER translation check:", file=sys.stderr)
            for error in errors:
                print(f"  {error}", file=sys.stderr)
            raise SystemExit(1)
        print("TRASER: translates to GWDM with input and output validation")


def _dataset(args: argparse.Namespace) -> DatasetDir:
    return DatasetDir.find(args.dataset, schema=args.schema)


def cmd_validate(args: argparse.Namespace) -> None:
    if args.dataset:
        payload = build_payload(_dataset(args), args.version or VALIDATE_VERSION)
        _check(payload, f"{args.dataset} (built)", SCHEMA_MODEL, SCHEMA_VERSION, args.traser)
    else:
        _check(_load_json(args.file), str(args.file), args.schema_model, args.schema_version, args.traser)


def cmd_build(args: argparse.Namespace) -> None:
    payload = build_payload(_dataset(args), args.version)
    text = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(text)
        print(f"Wrote {args.output}")
    else:
        print(text, end="")


def _status(args: argparse.Namespace, gateway: dict[str, Any]) -> str:
    """--status if given, else gateway.yaml's status, else DRAFT."""
    return args.status or gateway.get("status") or "DRAFT"


def _dataset_client(args: argparse.Namespace, gateway: dict[str, Any]) -> GatewayClient:
    """A client for gateway.yaml's team. --team-id or $GATEWAY_TEAM_ID, if set, must agree."""
    client = _client(args, default_team_id=gateway["team_id"])
    if client.config.team_id != gateway["team_id"]:
        client.close()
        raise CommandError(
            f"gateway.yaml is for team {gateway['team_id']} but the credentials are for team "
            f"{client.config.team_id}"
        )
    return client


def _create_dataset(args: argparse.Namespace) -> None:
    if not args.version:
        raise CommandError("--version is required with --dataset")
    dataset = _dataset(args)
    gateway = dataset.load_gateway()
    if gateway.get("dataset_id"):
        raise CommandError(
            f"{dataset.gateway} already has dataset_id {gateway['dataset_id']}; use push to update it"
        )
    payload = build_payload(dataset, args.version)
    _check(payload, f"{args.dataset} (built)", SCHEMA_MODEL, SCHEMA_VERSION, traser=not args.skip_traser)

    status = _status(args, gateway)
    with _dataset_client(args, gateway) as client:
        result = client.create(payload, status=status, schema=DECLARED_SCHEMA)
        # Record the ID before anything else can fail, so it is never lost.
        dataset.record_created(result.dataset_id, None)
        pid = client.get(result.dataset_id)["data"].get("pid")
        dataset.record_created(result.dataset_id, pid)
    print(f"Created {status} dataset {result.dataset_id} (pid {pid}); recorded in {dataset.gateway}")


def cmd_push(args: argparse.Namespace) -> None:
    dataset = _dataset(args)
    gateway = dataset.load_gateway()
    status = _status(args, gateway)
    payload = build_payload(dataset, args.version)
    _check(payload, f"{args.dataset} (built)", SCHEMA_MODEL, SCHEMA_VERSION, traser=not args.skip_traser)

    dataset_id = gateway.get("dataset_id")
    if not dataset_id:
        raise CommandError(
            f"{dataset.gateway} has no dataset_id. Create the dataset once with "
            f"`gateway-publish create --dataset {args.dataset} --version {args.version}` "
            "(then commit gateway.yaml), "
            "or recover the ID with `gateway-publish list --status draft --title ...`."
        )

    if args.dry_run:
        base_url = (args.base_url or os.environ.get("GATEWAY_BASE_URL") or DEFAULT_BASE_URL).rstrip("/")
        print(f"DRY RUN: would send (credential headers omitted)\n"
              f"PUT {base_url}/v3/teams/{gateway['team_id']}/datasets/{dataset_id}")
        _print_json(GatewayClient._body(payload, status, DECLARED_SCHEMA))
        return

    title = payload["summary"]["title"]
    with _dataset_client(args, gateway) as client:
        before = latest_version(client.get(dataset_id))
        client.update(dataset_id, payload, status=status, schema=DECLARED_SCHEMA)
        after = latest_version(client.get(dataset_id))

    print(f"Dataset {dataset_id}: version {before.version} -> {after.version}, status {status}")
    problems = []
    if after.version <= before.version:
        problems.append(f"no new version (still {after.version})")
    if after.title != title:
        problems.append(f"retrieved title is {after.title!r}, expected {title!r}")
    if problems:
        raise CommandError("Read-back check failed: " + "; ".join(problems))
    print("OK: new version with the expected title")


def add_status(parser: argparse.ArgumentParser, default: str = "DRAFT") -> None:
    parser.add_argument(
        "--status",
        choices=STATUSES,
        help=f"dataset status to set (default: {default}). The Gateway skips its validation for DRAFT",
    )


def add_dataset(parser: argparse.ArgumentParser, positional: bool) -> None:
    if positional:
        parser.add_argument("dataset", type=Path, help="dataset directory (holds gateway/)")
    parser.add_argument("--schema", type=Path,
                        help="LinkML schema (default: the only *.yaml in the dataset directory, else in its schemas/)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="gateway-publish", description=__doc__)
    parser.add_argument("--base-url", help=f"Gateway API base URL (default: $GATEWAY_BASE_URL, else {DEFAULT_BASE_URL})")
    parser.add_argument("--team-id", type=int,
                        help="Gateway team ID (default: $GATEWAY_TEAM_ID, else gateway.yaml's team_id for dataset commands)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("create", help="create a dataset from a metadata file or, once, from a dataset directory")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path, help="metadata JSON (Phase 0 testing)")
    source.add_argument("--dataset", type=Path, help="dataset directory; writes the new ID to gateway/gateway.yaml")
    p.add_argument("--version", help="metadata version, with --dataset")
    p.add_argument("--skip-traser", action="store_true", help="with --dataset, skip the TRASER check")
    add_dataset(p, positional=False)
    add_status(p, default="gateway.yaml's status, else DRAFT")
    p.set_defaults(func=cmd_create)

    p = sub.add_parser("update", help="push a new version of a dataset")
    p.add_argument("--id", type=int, required=True)
    p.add_argument("--file", type=Path, required=True)
    add_status(p)
    p.set_defaults(func=cmd_update)

    p = sub.add_parser("get", help="retrieve a dataset")
    p.add_argument("--id", type=int, required=True)
    p.add_argument("--schema-model")
    p.add_argument("--schema-version")
    p.set_defaults(func=cmd_get)

    p = sub.add_parser("delete", help="delete a dataset")
    p.add_argument("--id", type=int, required=True)
    p.add_argument("--confirm", type=int, help="repeat the dataset ID to confirm")
    p.set_defaults(func=cmd_delete)

    p = sub.add_parser("list", help="list the team's datasets")
    p.add_argument("--status", choices=["active", "draft", "archived"], default="active")
    p.add_argument("--title", help="substring match on title")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("validate", help="validate a metadata file or built dataset offline against a bundled schema")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path)
    source.add_argument("--dataset", type=Path, help=f"dataset directory; built and checked against {SCHEMA_MODEL} {SCHEMA_VERSION}")
    p.add_argument("--version", help=f"metadata version to build with --dataset (default: {VALIDATE_VERSION})")
    add_dataset(p, positional=False)
    p.add_argument("--schema-model", default="HDRUK")
    p.add_argument("--schema-version", default="4.1.0")
    p.add_argument("--traser", action="store_true",
                   help="also translate via TRASER to GWDM as the Gateway does (sends the file to TRASER)")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("build", help="build the payload for a dataset directory")
    add_dataset(p, positional=True)
    p.add_argument("--version", required=True, help="metadata version (in a dataset repo: the release version)")
    p.add_argument("-o", "--output", type=Path, help="write to this file (default: stdout)")
    p.set_defaults(func=cmd_build)

    p = sub.add_parser("push", help="build, validate and push a new version of an existing dataset")
    add_dataset(p, positional=True)
    p.add_argument("--version", required=True, help="metadata version (in a dataset repo: the release version)")
    p.add_argument("--dry-run", action="store_true", help="print the request instead of sending it")
    p.add_argument("--skip-traser", action="store_true", help="skip the TRASER check")
    add_status(p, default="gateway.yaml's status, else DRAFT")
    p.set_defaults(func=cmd_push)

    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except (BuildError, ConfigError, CommandError, GatewayError, TraserError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
