"""Tests for gateway_publish.py. Run: uv run pytest"""
import json

import httpx
import pytest

import gateway_publish as gp

SCHEMA = """
id: https://example.org/test
name: test
imports: [linkml:types]
prefixes: {linkml: https://w3id.org/linkml/}
default_range: string
classes:
  Visit:
    description: One row per visit.
    tree_root: true
    slots: [visit_id, nhs_number, outcome, note]
  NotATable:
    slots: [visit_id]
slots:
  visit_id: {description: Visit identifier., range: integer}
  nhs_number: {description: Pseudonymised NHS number., annotations: {sensitivity: pseudonymised}}
  outcome: {description: How the visit ended., range: Outcome}
  note: {description: ""}
enums:
  Outcome:
    permissible_values:
      "01": {description: Discharged}
      "99": {}
"""

METADATA = """
summary:
  title: Test Visits
  contactPoint: data@example.org
provenance:
  temporal:
    startDate: 2009-01-01
"""

URLS = ["--gateway-url", "https://gateway.test/api", "--traser-url", "https://traser.test"]

GATEWAY = """
team_id: 74
team_name: NUH
status: DRAFT
dataset_id: null
pid: null
"""


@pytest.fixture
def dataset(tmp_path, monkeypatch):
    (tmp_path / "schemas").mkdir()
    (tmp_path / "schemas" / "test.yaml").write_text(SCHEMA)
    (tmp_path / "gateway").mkdir()
    (tmp_path / "gateway" / "metadata.yaml").write_text(METADATA)
    (tmp_path / "gateway" / "gateway.yaml").write_text(GATEWAY)
    monkeypatch.setenv("GATEWAY_APP_ID", "app-secret")
    monkeypatch.setenv("GATEWAY_CLIENT_ID", "client-secret")
    return tmp_path


@pytest.fixture
def gateway(monkeypatch):
    """A fake Gateway and TRASER. Set `traser_status` to make TRASER reject the metadata."""
    class Fake:
        requests: list
        traser_status = 200
        version = 0
        title = None

        def __call__(self, request):
            self.requests.append(request)
            if request.url.path == "/translate":
                return httpx.Response(self.traser_status, json={"message": "Input metadata validation failed", "details": {
                    "validationErrors": [{"instancePath": "/summary", "message": "bad"}]}})
            if request.method in ("POST", "PUT"):
                self.version += 1
                self.title = json.loads(request.content)["metadata"]["metadata"]["summary"]["title"]
                return httpx.Response(201, json={"data": 2080})
            return httpx.Response(200, json={"data": {"pid": "pid-1", "versions": [{"version": self.version, "title": self.title}]}})

    fake = Fake()
    fake.requests = []
    monkeypatch.setattr(gp, "transport", httpx.MockTransport(fake))
    return fake


def test_build(dataset):
    payload, _ = gp.build(dataset, None, "v1.2.3")
    assert payload["version"] == "1.2.3"
    assert payload["provenance"]["temporal"]["startDate"] == "2009-01-01"  # not a date object
    assert payload["summary"]["dataCustodian"] == {"identifier": "74", "name": "NUH", "contactPoint": "data@example.org"}
    [table] = payload["structuralMetadata"]["tables"]
    assert table["name"] == "Visit"
    assert table["columns"] == [
        {"name": "visit_id", "dataType": "integer", "description": "Visit identifier.", "sensitive": False},
        {"name": "nhs_number", "dataType": "string", "description": "Pseudonymised NHS number.", "sensitive": True},
        {"name": "outcome", "dataType": "string", "description": "How the visit ended.", "sensitive": False,
         "values": [{"name": "01", "description": "Discharged"}, {"name": "99", "description": None}]},
        {"name": "note", "dataType": "string", "description": None, "sensitive": False},
    ]


@pytest.mark.parametrize("metadata, version, error", [
    ("summary: {title: TODO}", "1.0.0", "TODOs at: /summary/title"),
    ("version: 9.9.9", "1.0.0", "must not set fields that are generated: version"),
    ("summary: {title: x}", "1.0", "major.minor.patch"),
])
def test_build_errors(dataset, metadata, version, error):
    (dataset / "gateway" / "metadata.yaml").write_text(metadata)
    with pytest.raises(gp.Error, match=error):
        gp.build(dataset, None, version)


def test_create_then_push(dataset, gateway, capsys):
    gp.main(["create", str(dataset), "--version", "1.0.0", *URLS])
    assert "dataset_id: 2080\n  pid: pid-1" in capsys.readouterr().out
    gateway_yaml = dataset / "gateway" / "gateway.yaml"
    assert gateway_yaml.read_text() == GATEWAY  # create doesn't write to the repo
    gateway_yaml.write_text(GATEWAY.replace("dataset_id: null", "dataset_id: 2080").replace("pid: null", "pid: pid-1"))
    post = next(r for r in gateway.requests if r.method == "POST" and r.url.path != "/translate")
    assert str(post.url).startswith("https://gateway.test/api/v2/teams/74/datasets")
    assert post.headers["x-application-id"] == "app-secret"
    assert json.loads(post.content)["status"] == "DRAFT"

    gp.main(["push", str(dataset), "--version", "1.1.0", "--status", "ACTIVE", *URLS])
    put = next(r for r in gateway.requests if r.method == "PUT")
    assert put.url.path == "/api/v3/teams/74/datasets/2080"
    body = json.loads(put.content)
    assert body["status"] == "ACTIVE" and body["create_origin"] == "API"
    assert body["metadata"]["schemaModel"] == "HDRUK" and body["metadata"]["metadata"]["identifier"] == "pid-1"
    out = capsys.readouterr().out
    assert "version 1 -> 2, status ACTIVE" in out
    assert "secret" not in out


def test_traser_rejection_stops_push(dataset, gateway, capsys):
    gateway.traser_status = 400
    with pytest.raises(SystemExit):
        gp.main(["create", str(dataset), "--version", "1.0.0", *URLS])
    assert "%0A  /summary: bad" in capsys.readouterr().out  # one ::error:: annotation
    assert all(r.url.host == "traser.test" for r in gateway.requests)


def test_push_needs_dataset_id(dataset, gateway, capsys):
    with pytest.raises(SystemExit):
        gp.main(["push", str(dataset), "--version", "1.0.0", *URLS])
    assert "::error::gateway.yaml has no dataset_id" in capsys.readouterr().out


def test_dry_run_sends_nothing(dataset, gateway, monkeypatch, capsys):
    monkeypatch.delenv("GATEWAY_APP_ID")
    (dataset / "gateway" / "gateway.yaml").write_text(GATEWAY.replace("dataset_id: null", "dataset_id: 5"))
    gp.main(["push", str(dataset), "--version", "2.0.0", "--dry-run", "--skip-traser", *URLS])
    assert "PUT https://gateway.test/api/v3/teams/74/datasets/5" in capsys.readouterr().out
    assert gateway.requests == []
