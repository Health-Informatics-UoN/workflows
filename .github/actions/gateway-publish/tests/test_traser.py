import json

import httpx
import pytest

from gateway_publish.traser import TraserError, traser_errors


def run(status_code, body, metadata=None):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(status_code, json=body)

    errors = traser_errors(metadata or {"summary": {}}, "4.1.0", transport=httpx.MockTransport(handler))
    return errors, requests


def test_request_matches_gateway_call():
    errors, requests = run(200, {"required": {}}, {"summary": {"title": "T"}})
    assert errors == []
    request = requests[0]
    assert request.url.path == "/translate"
    assert dict(request.url.params) == {
        "input_schema": "HDRUK",
        "input_version": "4.1.0",
        "output_schema": "GWDM",
        "output_version": "2.2",
        "validate_input": "1",
        "validate_output": "1",
    }
    body = json.loads(request.content)
    assert body["metadata"] == {"summary": {"title": "T"}}
    assert set(body["extra"]) == {"id", "pid", "datasetType", "publisherId", "publisherName"}


def test_input_validation_errors():
    errors, _ = run(400, {
        "message": "Input metadata validation failed",
        "details": {"validationErrors": [
            {"instancePath": "/summary", "message": "must have required property 'title'"},
        ], "data": {}},
    })
    assert errors == [
        "Input metadata validation failed:",
        "  /summary: must have required property 'title'",
    ]


def test_output_validation_errors():
    errors, _ = run(400, {
        "message": "Output metadata validation failed",
        "details": [{"instancePath": "/required", "message": "bad"}],
    })
    assert errors == ["Output metadata validation failed:", "  /required: bad"]


def test_server_error_raises():
    with pytest.raises(TraserError, match="HTTP 500"):
        run(500, {"message": "Failed to execute translation"})
