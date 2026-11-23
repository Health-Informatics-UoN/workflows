import json
import os
import shutil
from datetime import UTC, datetime
from pathlib import Path

import pytest
import yaml

from gateway_publish.build import BuildError, DatasetDir, build_payload, find_todos, structural_metadata

FIXTURE = Path(__file__).parent / "fixtures" / "dataset"
GOLDEN = Path(__file__).parent / "fixtures" / "dataset.golden.json"
NOW = datetime(2026, 1, 2, 3, 4, 5, tzinfo=UTC)


@pytest.fixture
def dataset(tmp_path) -> Path:
    """A writable copy of the test dataset directory."""
    root = tmp_path / "dataset"
    shutil.copytree(FIXTURE, root)
    return root


def edit_yaml(path: Path, change) -> None:
    data = yaml.safe_load(path.read_text())
    change(data)
    path.write_text(yaml.safe_dump(data, sort_keys=False))


def test_golden(dataset):
    """Regenerate with UPDATE_GOLDEN=1 after an intended change, and review the diff."""
    payload = build_payload(DatasetDir.find(dataset), "1.2.3", now=NOW)
    if os.environ.get("UPDATE_GOLDEN"):
        GOLDEN.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    assert payload == json.loads(GOLDEN.read_text())


def test_build_fills_gateway_fields(dataset):
    edit_yaml(dataset / "gateway" / "gateway.yaml", lambda g: g.update(pid="abc-123"))
    payload = build_payload(DatasetDir.find(dataset), "1.2.3", now=NOW)
    assert payload["version"] == "1.2.3"
    assert payload["identifier"] == "abc-123"
    assert payload["issued"] == payload["modified"] == "2026-01-02T03:04:05.000Z"
    assert payload["summary"]["dataCustodian"] == {
        "identifier": "74",
        "name": "Nottingham University Hospitals - NHS Trust",
        "contactPoint": "data.access@example.org",
    }


def test_structural_metadata_from_linkml():
    tables = structural_metadata(FIXTURE / "schema.yaml")["tables"]
    # Only tree_root classes become tables.
    assert [t["name"] for t in tables] == ["Visit"]
    columns = {c["name"]: c for c in tables[0]["columns"]}
    assert list(columns) == ["visit_id", "pseudo_nhs_number", "visit_date", "outcome", "note"]
    assert columns["visit_id"]["dataType"] == "integer"
    assert columns["visit_date"]["dataType"] == "date"
    assert columns["pseudo_nhs_number"]["sensitive"] is True
    assert columns["visit_id"]["sensitive"] is False
    # An empty LinkML description becomes null; HDRUK rejects "".
    assert columns["note"]["description"] is None
    # Enums are strings, with their permissible values.
    assert columns["outcome"]["dataType"] == "string"
    assert columns["outcome"]["values"] == [
        {"name": "01", "description": "Discharged"},
        {"name": "02", "description": "Admitted"},
        {"name": "99", "description": None},
    ]
    assert "values" not in columns["visit_id"]


def test_todos_block_build(dataset):
    edit_yaml(dataset / "gateway" / "metadata.yaml",
              lambda m: m["summary"].update(contactPoint="TODO who?", keywords=["a", "TODO"]))
    with pytest.raises(BuildError, match="/summary/contactPoint, /summary/keywords/1"):
        build_payload(DatasetDir.find(dataset), "1.2.3")


def test_metadata_must_not_set_generated_fields(dataset):
    def change(m):
        m["version"] = "9.9.9"
        m["summary"]["dataCustodian"] = {"name": "x"}
    edit_yaml(dataset / "gateway" / "metadata.yaml", change)
    with pytest.raises(BuildError, match="version, summary/dataCustodian"):
        build_payload(DatasetDir.find(dataset), "1.2.3")


def test_unquoted_dates_stay_strings(dataset):
    path = dataset / "gateway" / "metadata.yaml"
    path.write_text(path.read_text().replace('startDate: "2009-01-01"', "startDate: 2009-01-01"))
    payload = build_payload(DatasetDir.find(dataset), "1.2.3")
    assert payload["provenance"]["temporal"]["startDate"] == "2009-01-01"


@pytest.mark.parametrize("version, expected", [("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3")])
def test_version(dataset, version, expected):
    assert build_payload(DatasetDir.find(dataset), version)["version"] == expected


@pytest.mark.parametrize("version", ["1.2", "1.2.3-rc.1", "latest", ""])
def test_bad_version(dataset, version):
    with pytest.raises(BuildError, match="must be major.minor.patch"):
        build_payload(DatasetDir.find(dataset), version)


def test_schema_found_in_schemas_folder(dataset):
    """The dataset-repo layout: schemas/<name>.yaml next to gateway/."""
    (dataset / "schemas").mkdir()
    (dataset / "schema.yaml").rename(dataset / "schemas" / "sact.yaml")
    assert DatasetDir.find(dataset).schema == dataset / "schemas" / "sact.yaml"


def test_more_than_one_schema_needs_schema_option(dataset):
    (dataset / "other.yaml").write_text("id: x\n")
    with pytest.raises(BuildError, match="More than one \\*.yaml .* pass the LinkML schema with --schema"):
        DatasetDir.find(dataset)
    assert DatasetDir.find(dataset, schema=dataset / "schema.yaml").schema.name == "schema.yaml"


def test_no_schema(dataset):
    (dataset / "schema.yaml").unlink()
    with pytest.raises(BuildError, match="No LinkML schema"):
        DatasetDir.find(dataset)


def test_gateway_yaml_needs_team(dataset):
    edit_yaml(dataset / "gateway" / "gateway.yaml", lambda g: g.pop("team_id"))
    with pytest.raises(BuildError, match="'team_id' is required"):
        build_payload(DatasetDir.find(dataset), "1.2.3")


def test_bad_status(dataset):
    edit_yaml(dataset / "gateway" / "gateway.yaml", lambda g: g.update(status="LIVE"))
    with pytest.raises(BuildError, match="status must be one of ACTIVE, DRAFT"):
        build_payload(DatasetDir.find(dataset), "1.2.3")


def test_record_created_keeps_comments(dataset):
    found = DatasetDir.find(dataset)
    found.record_created(2080, "abc-123")
    text = found.gateway.read_text()
    assert "# Status each release publishes with" in text
    assert "dataset_id: 2080\n" in text and "pid: abc-123\n" in text
    assert yaml.safe_load(text)["status"] == "DRAFT"


def test_find_todos():
    assert find_todos({"a": "TODO x", "b": ["ok", " TODO"], "c": {"d": 1}}) == ["/a", "/b/1"]
