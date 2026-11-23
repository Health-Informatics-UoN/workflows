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

DECLARED_SCHEMA = (SCHEMA_MODEL, SCHEMA_VERSION)
# Any valid version will do when only checking a dataset directory.
VALIDATE_VERSION = "0.0.0"


class CommandError(Exception):
    pass


def _print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, ensure_ascii=False))


def _client(args: argparse.Namespace, default_team_id: int | None = None) -> GatewayClient:
    """`default_team_id` applies only when neither --team-id nor $GATEWAY_TEAM_ID is set."""
    team_id = args.team_id
    if team_id is None and not os.environ.get("GATEWAY_TEAM_ID"):
        team_id = default_team_id
    return GatewayClient(GatewayConfig.from_env(base_url=args.base_url, team_id=team_id))


def _dataset(args: argparse.Namespace) -> DatasetDir:
    return DatasetDir.find(args.dataset, schema=args.schema)


def _check(payload: dict[str, Any], label: str, skip_traser: bool) -> None:
    """Validate with TRASER the way the Gateway does; exit 1 with readable errors on failure."""
    if skip_traser:
        print(f"{label}: built (TRASER check skipped)")
        return
    errors = traser_errors(payload, SCHEMA_VERSION, SCHEMA_MODEL)
    if errors:
        print(f"{label} failed the TRASER check ({SCHEMA_MODEL} {SCHEMA_VERSION} to GWDM):", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"{label} is valid {SCHEMA_MODEL} {SCHEMA_VERSION} and translates to GWDM (TRASER)")


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


def cmd_build(args: argparse.Namespace) -> None:
    payload = build_payload(_dataset(args), args.version)
    text = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(text)
        print(f"Wrote {args.output}")
    else:
        print(text, end="")


def cmd_validate(args: argparse.Namespace) -> None:
    payload = build_payload(_dataset(args), args.version or VALIDATE_VERSION)
    _check(payload, str(args.dataset), args.skip_traser)


def cmd_create(args: argparse.Namespace) -> None:
    dataset = _dataset(args)
    gateway = dataset.load_gateway()
    if gateway.get("dataset_id"):
        raise CommandError(
            f"{dataset.gateway} already has dataset_id {gateway['dataset_id']}; use push to update it"
        )
    payload = build_payload(dataset, args.version)
    _check(payload, str(args.dataset), args.skip_traser)

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
    _check(payload, str(args.dataset), args.skip_traser)

    dataset_id = gateway.get("dataset_id")
    if not dataset_id:
        raise CommandError(
            f"{dataset.gateway} has no dataset_id. Create the dataset once with "
            f"`gateway-publish create {args.dataset} --version {args.version}` "
            "and commit gateway.yaml."
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


def cmd_get(args: argparse.Namespace) -> None:
    with _client(args) as client:
        _print_json(client.get(args.id, SCHEMA_MODEL, SCHEMA_VERSION))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="gateway-publish", description=__doc__)
    parser.add_argument("--base-url", help=f"Gateway API base URL (default: $GATEWAY_BASE_URL, else {DEFAULT_BASE_URL})")
    parser.add_argument("--team-id", type=int,
                        help="Gateway team ID (default: $GATEWAY_TEAM_ID, else gateway.yaml's team_id)")
    sub = parser.add_subparsers(dest="command", required=True)

    def dataset_command(name: str, help: str, version_required: bool = True) -> argparse.ArgumentParser:
        p = sub.add_parser(name, help=help)
        p.add_argument("dataset", type=Path, help="dataset directory (holds gateway/)")
        p.add_argument("--schema", type=Path,
                       help="LinkML schema (default: the only *.yaml in the dataset directory, else in its schemas/)")
        p.add_argument("--version", required=version_required,
                       help="metadata version, major.minor.patch (in a dataset repo: the release version)")
        return p

    def options(p: argparse.ArgumentParser, status: bool = True) -> None:
        p.add_argument("--skip-traser", action="store_true", help="skip the TRASER check")
        if status:
            p.add_argument("--status", choices=STATUSES,
                           help="DRAFT or ACTIVE (default: gateway.yaml's status, else DRAFT)")

    p = dataset_command("build", "build the payload and print or save it")
    p.add_argument("-o", "--output", type=Path, help="write to this file (default: stdout)")
    p.set_defaults(func=cmd_build)

    p = dataset_command("validate", "build the payload and check it with TRASER", version_required=False)
    options(p, status=False)
    p.set_defaults(func=cmd_validate)

    p = dataset_command("create", "create the dataset on the Gateway, once; writes its ID to gateway.yaml")
    options(p)
    p.set_defaults(func=cmd_create)

    p = dataset_command("push", "validate and send a new version of the dataset, then read it back")
    p.add_argument("--dry-run", action="store_true", help="print the request instead of sending it")
    options(p)
    p.set_defaults(func=cmd_push)

    p = sub.add_parser("get", help="print a dataset's latest version as HDRUK 4.1.0")
    p.add_argument("--id", type=int, required=True)
    p.set_defaults(func=cmd_get)

    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except (BuildError, ConfigError, CommandError, GatewayError, TraserError) as e:
        print(f"error: {e}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
