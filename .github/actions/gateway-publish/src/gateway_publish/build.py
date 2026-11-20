"""Build a Gateway payload (HDRUK 4.1.0) from a dataset directory.

A dataset directory (in a dataset repo, the repo root) holds:
  <name>.yaml or schemas/<name>.yaml
                           LinkML schema; supplies structuralMetadata
  gateway/metadata.yaml    hand-written catalogue fields, in HDRUK 4.1.0 shape
  gateway/gateway.yaml     the Gateway team, the status to publish with and, once created,
                           the dataset ID and pid

`build_payload` merges them and fills the fields the Gateway overwrites anyway (identifier,
issued, modified, revisions, summary.dataCustodian) so the payload passes validation.
"""

import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import yaml
from linkml_runtime.utils.schemaview import SchemaView

from gateway_publish.client import STATUSES

SCHEMA_MODEL = "HDRUK"
SCHEMA_VERSION = "4.1.0"
TODO_MARKER = "TODO"
# Filled by build; metadata.yaml must not set them.
GENERATED_FIELDS = ("identifier", "version", "issued", "modified", "revisions", "structuralMetadata")


class BuildError(Exception):
    pass


class _Loader(yaml.SafeLoader):
    """SafeLoader that keeps unquoted dates (startDate: 2020-01-01) as strings, as HDRUK expects."""


_Loader.yaml_implicit_resolvers = {
    first: [(tag, regexp) for tag, regexp in resolvers if tag != "tag:yaml.org,2002:timestamp"]
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


@dataclass
class DatasetDir:
    root: Path
    schema: Path
    metadata: Path
    gateway: Path

    @classmethod
    def find(cls, root: Path, schema: Path | None = None) -> "DatasetDir":
        """`schema` defaults to the only *.yaml in `root`, or failing that in `root`/schemas."""
        if not root.is_dir():
            raise BuildError(f"Not a directory: {root}")
        if schema is None:
            schema = _find_schema(root)
        dataset = cls(root, schema, root / "gateway" / "metadata.yaml", root / "gateway" / "gateway.yaml")
        for path in (dataset.schema, dataset.metadata, dataset.gateway):
            if not path.is_file():
                raise BuildError(f"Missing {path}")
        return dataset

    def load_metadata(self) -> dict[str, Any]:
        return _load_yaml(self.metadata)

    def load_gateway(self) -> dict[str, Any]:
        gateway = _load_yaml(self.gateway)
        for key in ("team_id", "team_name"):
            if not gateway.get(key):
                raise BuildError(f"{self.gateway}: '{key}' is required")
        if gateway.get("status") not in (None, *STATUSES):
            raise BuildError(f"{self.gateway}: status must be one of {', '.join(STATUSES)}")
        return gateway

    def record_created(self, dataset_id: int, pid: str | None) -> None:
        """Write dataset_id and pid into gateway.yaml, keeping its comments and other keys."""
        text = self.gateway.read_text()
        for key, value in (("dataset_id", dataset_id), ("pid", pid)):
            line = f"{key}: {yaml.safe_dump(value, default_style=None).splitlines()[0]}"
            text, found = re.subn(rf"^{key}:.*$", line, text, count=1, flags=re.MULTILINE)
            if not found:
                text = text.rstrip("\n") + f"\n{line}\n"
        self.gateway.write_text(text)


def _find_schema(root: Path) -> Path:
    for folder in (root, root / "schemas"):
        schemas = sorted(folder.glob("*.yaml"))
        if len(schemas) == 1:
            return schemas[0]
        if schemas:
            found = ", ".join(p.name for p in schemas)
            raise BuildError(f"More than one *.yaml in {folder} ({found}); pass the LinkML schema with --schema")
    raise BuildError(f"No LinkML schema (*.yaml) in {root} or {root / 'schemas'}; pass it with --schema")


def _load_yaml(path: Path) -> dict[str, Any]:
    try:
        data = yaml.load(path.read_text(), Loader=_Loader)
    except yaml.YAMLError as e:
        raise BuildError(f"{path} is not valid YAML: {e}") from None
    if not isinstance(data, dict):
        raise BuildError(f"{path} must contain a mapping")
    return data


def find_todos(value: Any, path: str = "") -> list[str]:
    """Paths of string values that still start with the TODO marker."""
    if isinstance(value, dict):
        return [p for k, v in value.items() for p in find_todos(v, f"{path}/{k}")]
    if isinstance(value, list):
        return [p for i, v in enumerate(value) for p in find_todos(v, f"{path}/{i}")]
    if isinstance(value, str) and value.strip().startswith(TODO_MARKER):
        return [path or "/"]
    return []


def _values(sv: SchemaView, range_name: str | None) -> list[dict[str, Any]] | None:
    """An enum's permissible values as HDRUK column values; None for other ranges."""
    enum = sv.get_enum(range_name, strict=False) if range_name else None
    if enum is None:
        return None
    return [
        {"name": name, "description": (pv.description or "").strip() or None}
        for name, pv in enum.permissible_values.items()
    ]


def _data_type(sv: SchemaView, range_name: str | None) -> str:
    if range_name is None:
        return "string"
    # Enums are stored as their (string) permissible values.
    return "string" if sv.get_enum(range_name, strict=False) else range_name


def structural_metadata(schema_path: Path) -> dict[str, Any]:
    """One table per tree_root class, one column per slot (as nuh-data's gen_datadict.py)."""
    sv = SchemaView(str(schema_path))
    roots = [c for c in sv.all_classes().values() if c.tree_root]
    if not roots:
        raise BuildError(f"{schema_path}: no tree_root class found")
    tables = []
    for cls in roots:
        columns = []
        for slot_name in sv.class_slots(cls.name):
            slot = sv.induced_slot(slot_name, cls.name)
            column = {
                "name": slot.name,
                "dataType": _data_type(sv, slot.range),
                # HDRUK rejects empty descriptions.
                "description": (slot.description or "").strip() or None,
                "sensitive": "sensitivity" in slot.annotations,
            }
            values = _values(sv, slot.range)
            if values is not None:
                column["values"] = values
            columns.append(column)
        tables.append({"name": cls.name, "description": (cls.description or "").strip() or None, "columns": columns})
    return {"tables": tables}


def _timestamp(now: datetime) -> str:
    return now.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def _semver(version: str) -> str:
    """HDRUK needs major.minor.patch; release tags may carry a leading v."""
    plain = version.removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+", plain):
        raise BuildError(f"Version {version!r} must be major.minor.patch, e.g. 1.2.3 (a leading v is allowed)")
    return plain


def build_payload(dataset: DatasetDir, version: str, now: datetime | None = None) -> dict[str, Any]:
    version = _semver(version)
    metadata = dataset.load_metadata()
    gateway = dataset.load_gateway()

    todos = find_todos(metadata)
    if todos:
        raise BuildError(f"{dataset.metadata} still has TODOs at: {', '.join(todos)}")
    clashes = [f for f in GENERATED_FIELDS if f in metadata]
    if "dataCustodian" in metadata.get("summary", {}):
        clashes.append("summary/dataCustodian")
    if clashes:
        raise BuildError(f"{dataset.metadata} must not set fields that build fills: {', '.join(clashes)}")

    stamp = _timestamp(now or datetime.now(UTC))
    summary = metadata.get("summary", {})
    payload = {
        "identifier": gateway.get("pid"),
        "version": version,
        "revisions": [],
        "issued": stamp,
        "modified": stamp,
        **metadata,
        "structuralMetadata": structural_metadata(dataset.schema),
    }
    # Required by the schema but replaced by the Gateway with the owning team.
    payload["summary"] = {
        **summary,
        "dataCustodian": {
            "identifier": str(gateway["team_id"]),
            "name": gateway["team_name"],
            "contactPoint": summary.get("contactPoint"),
        },
    }
    return payload
