"""Opt-in end-to-end test against the Gateway (live by default): create -> rename -> get -> delete.

The dataset is created as DRAFT and deleted at the end.
Skipped unless GATEWAY_LIVE_TESTS=1 (and GATEWAY_APP_ID, GATEWAY_CLIENT_ID, GATEWAY_TEAM_ID are set).
"""

import json
import os
import uuid

import pytest

from gateway_publish.client import GatewayClient, latest_version
from gateway_publish.config import GatewayConfig
from tests.conftest import FIXTURES

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(os.environ.get("GATEWAY_LIVE_TESTS") != "1", reason="GATEWAY_LIVE_TESTS=1 not set"),
]


def test_create_rename_get():
    metadata = json.loads((FIXTURES / "example-hdruk410.json").read_text())
    run_id = uuid.uuid4().hex[:8]
    metadata["summary"]["title"] = f"gateway-publish test {run_id}"

    with GatewayClient(GatewayConfig.from_env()) as client:
        created = client.create(metadata, status="DRAFT")
        try:
            before = latest_version(client.get(created.dataset_id))
            assert before.title == metadata["summary"]["title"]

            metadata["summary"]["title"] = f"gateway-publish test {run_id} renamed"
            client.update(created.dataset_id, metadata, status="DRAFT")

            after = latest_version(client.get(created.dataset_id))
            assert after.title == metadata["summary"]["title"]
            assert after.version > before.version
        finally:
            client.delete(created.dataset_id)
