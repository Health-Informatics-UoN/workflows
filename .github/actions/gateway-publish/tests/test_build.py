import json
import os
import shutil
from datetime import UTC, datetime
from pathlib import Path

import pytest
import yaml

from gateway_publish.build import BuildError, DatasetDir, build_payload, find_todos, structural_metadata
from gateway_publish.validate import validation_errors

# A copy of the demographics LinkML schema from nuh-data, with made-up catalogue values.
FIXTURE = Path(__file__).parent / "fixtures" / "demographics"
DEMOGRAPHICS_SCHEMA = FIXTURE / "demographics.yaml"
GOLDEN = Path(__file__).parent / "fixtures" / "demographics.golden.json"
NOW = datetime(2026, 1, 2, 3, 4, 5, tzinfo=UTC)


@pytest.fixture
def demographics(tmp_path) -> Path:
    """A writable copy of the demographics fixture."""
    root = tmp_path / "demographics"
    shutil.copytree(FIXTURE, root)
    return root


def edit_yaml(path: Path, change) -> None:
    data = yaml.safe_load(path.read_text())
    change(data)
    path.write_text(yaml.safe_dump(data))


def test_golden(demographics):
    """Regenerate with UPDATE_GOLDEN=1 after an intended change, and review the diff."""
    payload = build_payload(DatasetDir.find(demographics), "1.2.3", now=NOW)
    if os.environ.get("UPDATE_GOLDEN"):
        GOLDEN.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    assert payload == json.loads(GOLDEN.read_text())


def test_built_payload_is_valid(demographics):
    payload = build_payload(DatasetDir.find(demographics), "1.2.3", now=NOW)
    assert validation_errors(payload, "4.1.0") == []


def test_build_fills_gateway_fields(demographics):
    edit_yaml(demographics / "gateway" / "gateway.yaml", lambda g: g.update(pid="abc-123"))
    payload = build_payload(DatasetDir.find(demographics), "1.2.3", now=NOW)
    assert payload["version"] == "1.2.3"
    assert payload["identifier"] == "abc-123"
    assert payload["issued"] == payload["modified"] == "2026-01-02T03:04:05.000Z"
    assert payload["summary"]["dataCustodian"] == {
        "identifier": "74",
        "name": "Nottingham University Hospitals - NHS Trust",
        "contactPoint": "data.access@example.org",
    }


def test_structural_metadata_from_linkml():
    tables = structural_metadata(DEMOGRAPHICS_SCHEMA)["tables"]
    assert [t["name"] for t in tables] == ["CoreDemographics"]
    columns = {c["name"]: c for c in tables[0]["columns"]}
    assert len(columns) == 21
    assert columns["pseudo_nhs_number"]["sensitive"] is True
    assert columns["sex"]["sensitive"] is False
    assert columns["etl_id"]["dataType"] == "integer"
    assert columns["dob_first_of_month"]["dataType"] == "date"
    # An empty LinkML description becomes null; HDRUK rejects "".
    assert columns["ndo_run_date"]["description"] is None


def test_enum_range_is_string_with_values(tmp_path):
    schema = tmp_path / "s.yaml"
    schema.write_text(yaml.safe_dump({
        "id": "https://example.org/s", "name": "s", "imports": ["linkml:types"],
        "prefixes": {"linkml": "https://w3id.org/linkml/"}, "default_range": "string",
        "classes": {"T": {"tree_root": True, "slots": ["colour"]}},
        "slots": {"colour": {"range": "Colour"}},
        "enums": {"Colour": {"permissible_values": {"R": {"description": "Red"}, "B": {}}}},
    }, sort_keys=False))
    column = structural_metadata(schema)["tables"][0]["columns"][0]
    assert column["dataType"] == "string"
    assert column["values"] == [{"name": "R", "description": "Red"}, {"name": "B", "description": None}]


def test_todos_block_build(demographics):
    edit_yaml(demographics / "gateway" / "metadata.yaml",
              lambda m: m["summary"].update(contactPoint="TODO who?", keywords=["a", "TODO"]))
    with pytest.raises(BuildError, match="/summary/contactPoint, /summary/keywords/1"):
        build_payload(DatasetDir.find(demographics), "1.2.3")


def test_metadata_must_not_set_generated_fields(demographics):
    def change(m):
        m["version"] = "9.9.9"
        m["summary"]["dataCustodian"] = {"name": "x"}
    edit_yaml(demographics / "gateway" / "metadata.yaml", change)
    with pytest.raises(BuildError, match="version, summary/dataCustodian"):
        build_payload(DatasetDir.find(demographics), "1.2.3")


def test_dataset_dir_needs_one_schema(demographics):
    (demographics / "other.yaml").write_text("id: x\n")
    with pytest.raises(BuildError, match="More than one \\*.yaml .* pass the LinkML schema with --schema"):
        DatasetDir.find(demographics)
    assert DatasetDir.find(demographics, schema=demographics / "demographics.yaml").schema.name == "demographics.yaml"


def test_schema_found_in_schemas_folder(demographics):
    """The dataset-repo layout: schemas/<name>.yaml next to gateway/."""
    (demographics / "schemas").mkdir()
    (demographics / "demographics.yaml").rename(demographics / "schemas" / "demographics.yaml")
    assert DatasetDir.find(demographics).schema == demographics / "schemas" / "demographics.yaml"


def test_no_schema(demographics):
    (demographics / "demographics.yaml").unlink()
    with pytest.raises(BuildError, match="No LinkML schema"):
        DatasetDir.find(demographics)


def test_bad_status(demographics):
    edit_yaml(demographics / "gateway" / "gateway.yaml", lambda g: g.update(status="LIVE"))
    with pytest.raises(BuildError, match="status must be one of ACTIVE, DRAFT"):
        build_payload(DatasetDir.find(demographics), "1.2.3")


def test_record_created_keeps_comments(demographics):
    dataset = DatasetDir.find(demographics)
    dataset.record_created(2080, "abc-123")
    text = dataset.gateway.read_text()
    assert "# Status each release publishes with" in text
    assert "dataset_id: 2080\n" in text and "pid: abc-123\n" in text
    assert yaml.safe_load(text)["status"] == "DRAFT"


def test_gateway_yaml_needs_team(demographics):
    edit_yaml(demographics / "gateway" / "gateway.yaml", lambda g: g.pop("team_id"))
    with pytest.raises(BuildError, match="'team_id' is required"):
        build_payload(DatasetDir.find(demographics), "1.2.3")


def test_unquoted_dates_stay_strings(demographics):
    path = demographics / "gateway" / "metadata.yaml"
    path.write_text(path.read_text().replace('startDate: "2009-01-01"', "startDate: 2009-01-01"))
    payload = build_payload(DatasetDir.find(demographics), "1.2.3")
    assert payload["provenance"]["temporal"]["startDate"] == "2009-01-01"


@pytest.mark.parametrize("version, expected", [("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3")])
def test_version(demographics, version, expected):
    assert build_payload(DatasetDir.find(demographics), version)["version"] == expected


@pytest.mark.parametrize("version", ["1.2", "1.2.3-rc.1", "latest", ""])
def test_bad_version(demographics, version):
    with pytest.raises(BuildError, match="must be major.minor.patch"):
        build_payload(DatasetDir.find(demographics), version)


def test_find_todos():
    assert find_todos({"a": "TODO x", "b": ["ok", " TODO"], "c": {"d": 1}}) == ["/a", "/b/1"]
