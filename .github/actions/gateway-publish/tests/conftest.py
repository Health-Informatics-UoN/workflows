import pytest

from gateway_publish.config import GatewayConfig

APP_ID = "test-app-id-0123456789"
CLIENT_ID = "test-client-id-9876543210"
TEAM_ID = 42


@pytest.fixture
def gateway_env(monkeypatch):
    monkeypatch.setenv("GATEWAY_APP_ID", APP_ID)
    monkeypatch.setenv("GATEWAY_CLIENT_ID", CLIENT_ID)
    monkeypatch.setenv("GATEWAY_TEAM_ID", str(TEAM_ID))
    monkeypatch.delenv("GATEWAY_BASE_URL", raising=False)
    monkeypatch.delenv("GATEWAY_ALLOW_UNKNOWN_HOST", raising=False)


@pytest.fixture
def config(gateway_env) -> GatewayConfig:
    return GatewayConfig.from_env()


@pytest.fixture
def example_metadata() -> dict:
    return {"summary": {"title": "Example"}}


@pytest.fixture(autouse=True)
def no_retry_wait(monkeypatch):
    """Retried reads don't wait in tests; tests of the waits pass their own `sleep`."""
    monkeypatch.setattr("gateway_publish.client.RETRY_WAIT", 0.0)
