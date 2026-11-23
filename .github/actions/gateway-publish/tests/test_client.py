import json

import httpx
import pytest

from gateway_publish.client import GatewayClient, GatewayError, latest_version
from tests.conftest import APP_ID, CLIENT_ID


class Recorder:
    """httpx transport that records requests and replies with a canned response."""

    def __init__(self, status_code: int = 200, body=None, text: str | None = None):
        self.requests: list[httpx.Request] = []
        self.status_code = status_code
        self.body = body if body is not None else {"message": "success"}
        self.text = text

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.text is not None:
            return httpx.Response(self.status_code, text=self.text)
        return httpx.Response(self.status_code, json=self.body)

    @property
    def last(self) -> httpx.Request:
        return self.requests[-1]


def make_client(config, recorder: Recorder) -> GatewayClient:
    return GatewayClient(config, transport=httpx.MockTransport(recorder))


def test_create_request_shape(config, example_metadata):
    recorder = Recorder(201, {"message": "created", "data": 123, "version": 456})
    result = make_client(config, recorder).create(example_metadata, status="DRAFT")

    request = recorder.last
    assert request.method == "POST"
    assert str(request.url) == "https://api.healthdatagateway.org/api/v2/teams/42/datasets"
    assert request.headers["x-application-id"] == APP_ID
    assert request.headers["x-client-id"] == CLIENT_ID
    assert json.loads(request.content) == {
        "metadata": example_metadata,
        "create_origin": "API",
        "status": "DRAFT",
    }
    assert (result.dataset_id, result.version_id) == (123, 456)


def test_update_request_shape(config, example_metadata):
    recorder = Recorder()
    make_client(config, recorder).update(123, example_metadata, status="ACTIVE")

    request = recorder.last
    assert request.method == "PUT"
    assert request.url.path == "/api/v3/teams/42/datasets/123"
    assert json.loads(request.content)["status"] == "ACTIVE"


def test_get_with_schema(config):
    recorder = Recorder()
    make_client(config, recorder).get(123, "HDRUK", "4.1.0")
    assert recorder.last.url.path == "/api/v2/teams/42/datasets/123"
    assert dict(recorder.last.url.params) == {"schema_model": "HDRUK", "schema_version": "4.1.0"}


def test_rejects_unknown_status(config, example_metadata):
    recorder = Recorder()
    with pytest.raises(ValueError):
        make_client(config, recorder).create(example_metadata, status="ARCHIVED")
    assert recorder.requests == []


@pytest.mark.parametrize("model,version", [("HDRUK", None), (None, "4.1.0")])
def test_get_requires_both_schema_params(config, model, version):
    recorder = Recorder()
    with pytest.raises(ValueError):
        make_client(config, recorder).get(123, model, version)
    assert recorder.requests == []


@pytest.mark.parametrize(
    "status,message,hint_fragment",
    [
        (400, "Application permissions do not allow this request", "Permissions tab"),
        (400, "Application has not been enabled!", "App Info tab"),
        (400, "metadata is in an unknown format and cannot be processed", "gateway-publish validate"),
        (401, "No known integration matches the credentials provided", "GATEWAY_APP_ID"),
        (401, "The credentials provided are invalid", "GATEWAY_CLIENT_ID"),
        (401, "This Application is not allowed to interact with datasets from another team!", "GATEWAY_TEAM_ID"),
        (401, "Unauthorized", "credentials"),
        (404, "Dataset not found", "no dataset with that ID"),
        (500, "Dataset with id=1 cannot be found", "server error"),
        (503, "Service Unavailable", "retrying later"),
    ],
)
def test_error_mapping(config, status, message, hint_fragment):
    recorder = Recorder(status, {"code": status, "message": message, "details": {}})
    with pytest.raises(GatewayError) as exc:
        make_client(config, recorder).get(1)
    assert exc.value.status_code == status
    assert exc.value.message == message
    assert hint_fragment in exc.value.hint


def test_error_with_non_json_body(config):
    recorder = Recorder(502, text="<html>Bad Gateway</html>")
    with pytest.raises(GatewayError) as exc:
        make_client(config, recorder).get(1)
    assert "Bad Gateway" in exc.value.message


def test_error_text_has_no_credentials(config):
    recorder = Recorder(401, {"message": "Unauthorized"})
    with pytest.raises(GatewayError) as exc:
        make_client(config, recorder).get(1)
    assert APP_ID not in str(exc.value)
    assert CLIENT_ID not in str(exc.value)


@pytest.mark.parametrize("encode", [json.dumps, lambda x: x])
def test_latest_version(encode):
    stored = {"metadata": {"summary": {"title": "New"}}, "gwdmVersion": "2.0"}
    response = {"data": {"versions": [{"version": 3, "metadata": encode(stored)}]}}
    latest = latest_version(response)
    assert (latest.version, latest.title) == (3, "New")


def test_get_retries_server_errors(config, monkeypatch):
    monkeypatch.setattr("gateway_publish.client.RETRY_WAIT", 2.0)
    responses = iter([httpx.Response(502), httpx.Response(503), httpx.Response(200, json={"data": {}})])
    waits = []
    client = GatewayClient(config, transport=httpx.MockTransport(lambda r: next(responses)), sleep=waits.append)
    assert client.get(1) == {"data": {}}
    assert waits == [2.0, 4.0]


def test_get_gives_up_after_three_attempts(config):
    calls = []
    def handler(request):
        calls.append(request)
        return httpx.Response(500, json={"message": "boom"})
    client = GatewayClient(config, transport=httpx.MockTransport(handler), sleep=lambda s: None)
    with pytest.raises(GatewayError, match="HTTP 500"):
        client.get(1)
    assert len(calls) == 3


def test_get_retries_connection_errors(config):
    attempts = []
    def handler(request):
        attempts.append(request)
        if len(attempts) == 1:
            raise httpx.ConnectError("refused")
        return httpx.Response(200, json={"data": {}})
    client = GatewayClient(config, transport=httpx.MockTransport(handler), sleep=lambda s: None)
    assert client.get(1) == {"data": {}}


def test_update_is_not_retried(config):
    calls = []
    def handler(request):
        calls.append(request)
        return httpx.Response(502)
    client = GatewayClient(config, transport=httpx.MockTransport(handler), sleep=lambda s: None)
    with pytest.raises(GatewayError):
        client.update(1, {"summary": {}}, status="DRAFT")
    assert len(calls) == 1
