import json

import httpx
import pytest
import yaml

from gateway_publish import cli
from gateway_publish.client import GatewayClient
from gateway_publish.config import GatewayConfig
from tests.conftest import APP_ID, CLIENT_ID, FIXTURES, TEAM_ID
from tests.test_build import demographics, edit_yaml  # noqa: F401 (fixture)


class FakeGateway:
    """Minimal in-memory stand-in for the team dataset endpoints."""

    def __init__(self, bump_version_on_update: bool = True):
        self.datasets: dict[int, list[dict]] = {}
        self.statuses: dict[int, str] = {}
        self.bump_version_on_update = bump_version_on_update
        self.requests: list[httpx.Request] = []

    @staticmethod
    def _unwrap(metadata: dict) -> dict:
        # The Gateway accepts a bare document or the {"metadata", "schemaModel", "schemaVersion"} envelope.
        return metadata["metadata"] if "schemaModel" in metadata else metadata

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        parts = request.url.path.rstrip("/").split("/")
        dataset_id = int(parts[-1]) if parts[-1].isdigit() else None
        if request.method == "POST":
            new_id = len(self.datasets) + 1
            body = json.loads(request.content)
            self.statuses[new_id] = body["status"]
            self.datasets[new_id] = [self._unwrap(body["metadata"])]
            return httpx.Response(201, json={"message": "created", "data": new_id, "version": 1000 + new_id})
        if dataset_id not in self.datasets:
            return httpx.Response(404, json={"message": "Dataset not found"})
        versions = self.datasets[dataset_id]
        if request.method == "PUT":
            metadata = self._unwrap(json.loads(request.content)["metadata"])
            if self.bump_version_on_update:
                versions.append(metadata)
            else:
                versions[-1] = metadata
            return httpx.Response(200, json={"message": "success"})
        if request.method == "GET":
            latest = {"version": len(versions), "metadata": json.dumps({"metadata": versions[-1]})}
            data = {"id": dataset_id, "pid": f"pid-{dataset_id}", "versions": [latest]}
            return httpx.Response(200, json={"message": "success", "data": data})
        if request.method == "DELETE":
            del self.datasets[dataset_id]
            return httpx.Response(200, json={"message": "success"})
        return httpx.Response(405)


@pytest.fixture
def fake_gateway(gateway_env, monkeypatch):
    gateway = FakeGateway()
    monkeypatch.setattr(
        cli,
        "_client",
        lambda args, default_team_id=None: GatewayClient(
            GatewayConfig.from_env(team_id=args.team_id), transport=httpx.MockTransport(gateway)
        ),
    )
    return gateway


def run(*argv: str) -> None:
    cli.main(list(argv))


def test_create_update_get_delete(fake_gateway, capsys):
    fixture = FIXTURES / "example-hdruk410.json"
    run("create", "--file", str(fixture))
    assert "Created DRAFT dataset 1" in capsys.readouterr().out
    assert fake_gateway.statuses[1] == "DRAFT"

    run("update", "--id", "1", "--file", str(fixture))
    run("get", "--id", "1")
    assert '"version": 2' in capsys.readouterr().out

    with pytest.raises(SystemExit):
        run("delete", "--id", "1")
    assert "--confirm 1" in capsys.readouterr().err
    assert 1 in fake_gateway.datasets

    run("delete", "--id", "1", "--confirm", "1")
    assert fake_gateway.datasets == {}


def test_create_active(fake_gateway):
    run("create", "--file", str(FIXTURES / "example-hdruk410.json"), "--status", "ACTIVE")
    assert fake_gateway.statuses[1] == "ACTIVE"


def test_gateway_error_is_reported_without_traceback(fake_gateway, capsys):
    with pytest.raises(SystemExit) as exc:
        run("get", "--id", "99")
    assert exc.value.code == 1
    err = capsys.readouterr().err
    assert "HTTP 404" in err and "Likely cause" in err


def test_missing_credentials(monkeypatch, capsys):
    for name in ("GATEWAY_APP_ID", "GATEWAY_CLIENT_ID", "GATEWAY_TEAM_ID"):
        monkeypatch.delenv(name, raising=False)
    with pytest.raises(SystemExit):
        run("get", "--id", "1")
    assert "Missing environment variable" in capsys.readouterr().err


def test_output_never_contains_credentials(fake_gateway, capsys):
    run("create", "--file", str(FIXTURES / "example-hdruk410.json"))
    run("get", "--id", "1")
    captured = capsys.readouterr()
    for text in (captured.out, captured.err):
        assert APP_ID not in text and CLIENT_ID not in text


def test_validate(capsys):
    run("validate", "--file", str(FIXTURES / "example-hdruk410.json"), "--schema-version", "4.1.0")
    assert "is valid" in capsys.readouterr().out


def test_validate_reports_errors(tmp_path, capsys):
    broken = json.loads((FIXTURES / "example-hdruk410.json").read_text())
    del broken["summary"]["title"]
    path = tmp_path / "broken.json"
    path.write_text(json.dumps(broken))
    with pytest.raises(SystemExit):
        run("validate", "--file", str(path), "--schema-version", "4.1.0")
    assert "'title' is a required property" in capsys.readouterr().err


def test_validate_pinpoints_nested_enum_error(tmp_path, capsys):
    broken = json.loads((FIXTURES / "example-hdruk410.json").read_text())
    broken["provenance"]["temporal"]["timeLag"] = "Whenever"
    path = tmp_path / "broken.json"
    path.write_text(json.dumps(broken))
    with pytest.raises(SystemExit):
        run("validate", "--file", str(path), "--schema-version", "4.1.0")
    err = capsys.readouterr().err
    assert "/provenance/temporal/timeLag: 'Whenever' is not one of" in err
    assert "is not of type 'null'" not in err


# Dataset directories (Phase 1)

@pytest.fixture
def no_traser(monkeypatch):
    calls = []
    monkeypatch.setattr(cli, "traser_errors", lambda *a, **k: calls.append(a) or [])
    return calls


@pytest.fixture
def team_42(demographics):
    """The demographics fixture, pointed at the test team."""
    edit_yaml(demographics / "gateway" / "gateway.yaml", lambda g: g.update(team_id=TEAM_ID))
    return demographics


def gateway_yaml(dataset) -> dict:
    return yaml.safe_load((dataset / "gateway" / "gateway.yaml").read_text())


def test_build_command(demographics, tmp_path, capsys):
    out = tmp_path / "payload.json"
    run("build", str(demographics), "--version", "1.0.0", "-o", str(out))
    payload = json.loads(out.read_text())
    assert payload["version"] == "1.0.0"
    assert payload["structuralMetadata"]["tables"][0]["name"] == "CoreDemographics"


def test_build_reports_todos(demographics, capsys):
    edit_yaml(demographics / "gateway" / "metadata.yaml", lambda m: m["summary"].update(contactPoint="TODO"))
    with pytest.raises(SystemExit):
        run("build", str(demographics), "--version", "1.0.0")
    assert "still has TODOs" in capsys.readouterr().err


def test_validate_dataset(demographics, no_traser, capsys):
    run("validate", "--dataset", str(demographics), "--traser")
    assert "is valid HDRUK 4.1.0" in capsys.readouterr().out
    assert len(no_traser) == 1


def test_create_dataset_then_push(fake_gateway, team_42, no_traser, capsys):
    run("create", "--dataset", str(team_42), "--version", "1.0.0")
    assert gateway_yaml(team_42) == {
        "team_id": TEAM_ID, "team_name": "Nottingham University Hospitals - NHS Trust",
        "status": "DRAFT", "dataset_id": 1, "pid": "pid-1",
    }
    post = fake_gateway.requests[0]
    assert dict(post.url.params) == {"input_schema": "HDRUK", "input_version": "4.1.0"}
    body = json.loads(post.content)
    assert body["status"] == "DRAFT"
    assert body["metadata"]["schemaModel"] == "HDRUK" and body["metadata"]["schemaVersion"] == "4.1.0"
    assert body["metadata"]["metadata"]["version"] == "1.0.0"

    run("push", str(team_42), "--version", "1.1.0", "--status", "ACTIVE")
    out = capsys.readouterr().out
    assert "version 1 -> 2, status ACTIVE" in out and "OK: new version" in out
    put = next(r for r in fake_gateway.requests if r.method == "PUT")
    assert put.url.path == f"/api/v3/teams/{TEAM_ID}/datasets/1"
    body = json.loads(put.content)
    assert body["status"] == "ACTIVE"
    assert body["metadata"]["schemaModel"] == "HDRUK"
    # The pid recorded at create is sent as the identifier.
    assert body["metadata"]["metadata"]["identifier"] == "pid-1"
    assert fake_gateway.datasets[1][-1]["version"] == "1.1.0"
    assert len(no_traser) == 2


def test_create_dataset_refuses_when_id_exists(fake_gateway, team_42, no_traser, capsys):
    edit_yaml(team_42 / "gateway" / "gateway.yaml", lambda g: g.update(dataset_id=7))
    with pytest.raises(SystemExit):
        run("create", "--dataset", str(team_42), "--version", "1.0.0")
    assert "already has dataset_id 7" in capsys.readouterr().err
    assert fake_gateway.requests == []


def test_push_without_id_explains(fake_gateway, team_42, no_traser, capsys):
    with pytest.raises(SystemExit):
        run("push", str(team_42), "--version", "1.0.0")
    assert "Create the dataset once" in capsys.readouterr().err
    assert fake_gateway.requests == []


def test_push_refuses_other_team(fake_gateway, demographics, no_traser, capsys):
    edit_yaml(demographics / "gateway" / "gateway.yaml", lambda g: g.update(dataset_id=1))
    with pytest.raises(SystemExit):
        run("push", str(demographics), "--version", "1.0.0")
    assert "gateway.yaml is for team 74 but the credentials are for team 42" in capsys.readouterr().err
    assert fake_gateway.requests == []


def test_push_fails_without_new_version(fake_gateway, team_42, no_traser, capsys):
    run("create", "--dataset", str(team_42), "--version", "1.0.0")
    fake_gateway.bump_version_on_update = False
    with pytest.raises(SystemExit):
        run("push", str(team_42), "--version", "1.1.0")
    assert "Read-back check failed: no new version" in capsys.readouterr().err


def test_push_dry_run_sends_nothing(monkeypatch, team_42, no_traser, capsys):
    # No credentials and no transport: a dry run must not need either.
    for name in ("GATEWAY_APP_ID", "GATEWAY_CLIENT_ID", "GATEWAY_TEAM_ID", "GATEWAY_BASE_URL"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(cli, "_client", lambda args: pytest.fail("dry run created a client"))
    edit_yaml(team_42 / "gateway" / "gateway.yaml", lambda g: g.update(dataset_id=5))
    run("push", str(team_42), "--version", "2.0.0", "--dry-run")
    out = capsys.readouterr().out
    assert f"PUT https://api.healthdatagateway.org/api/v3/teams/{TEAM_ID}/datasets/5" in out
    body = json.loads(out[out.index("{"):])
    assert body["metadata"]["metadata"]["version"] == "2.0.0"
    assert body["create_origin"] == "API" and body["status"] == "DRAFT"


def test_push_uses_status_from_gateway_yaml(fake_gateway, team_42, no_traser, capsys):
    run("create", "--dataset", str(team_42), "--version", "1.0.0")
    edit_yaml(team_42 / "gateway" / "gateway.yaml", lambda g: g.update(status="ACTIVE"))
    run("push", str(team_42), "--version", "1.1.0")
    assert fake_gateway.statuses[1] == "DRAFT"  # create's status
    put = next(r for r in fake_gateway.requests if r.method == "PUT")
    assert json.loads(put.content)["status"] == "ACTIVE"
    # --status overrides gateway.yaml.
    run("push", str(team_42), "--version", "1.2.0", "--status", "DRAFT")
    put = [r for r in fake_gateway.requests if r.method == "PUT"][-1]
    assert json.loads(put.content)["status"] == "DRAFT"


def test_team_defaults_to_gateway_yaml(gateway_env, monkeypatch, team_42):
    monkeypatch.delenv("GATEWAY_TEAM_ID")
    client = cli._client(cli.build_parser().parse_args(["get", "--id", "1"]), default_team_id=TEAM_ID)
    assert client.config.team_id == TEAM_ID
    # An explicit team wins, and _dataset_client then refuses the mismatch.
    client = cli._client(cli.build_parser().parse_args(["--team-id", "7", "get", "--id", "1"]), default_team_id=TEAM_ID)
    assert client.config.team_id == 7
