import pytest

from gateway_publish.config import DEFAULT_BASE_URL, ConfigError, GatewayConfig
from tests.conftest import APP_ID, CLIENT_ID


def test_reads_env(config):
    assert config.base_url == "https://api.healthdatagateway.org/api" == DEFAULT_BASE_URL
    assert config.app_id.get_secret_value() == APP_ID
    assert config.team_id == 42


def test_secrets_not_in_repr(config):
    for text in (repr(config), str(config), config.model_dump_json()):
        assert APP_ID not in text
        assert CLIENT_ID not in text


def test_missing_env_names_every_variable(monkeypatch):
    for name in ("GATEWAY_APP_ID", "GATEWAY_CLIENT_ID", "GATEWAY_TEAM_ID"):
        monkeypatch.delenv(name, raising=False)
    with pytest.raises(ConfigError) as exc:
        GatewayConfig.from_env()
    assert "GATEWAY_APP_ID, GATEWAY_CLIENT_ID, GATEWAY_TEAM_ID" in str(exc.value)


def test_team_id_flag_overrides_env(gateway_env):
    assert GatewayConfig.from_env(team_id=7).team_id == 7


def test_dev_host_allowed(gateway_env):
    assert GatewayConfig.from_env(base_url="https://api.dev.hdruk.cloud/api").base_url.startswith("https://api.dev")


def test_refuses_unknown_host(gateway_env):
    with pytest.raises(ConfigError, match="unknown host example.org"):
        GatewayConfig.from_env(base_url="https://example.org/api")


def test_unknown_host_allowed_with_override(gateway_env, monkeypatch):
    monkeypatch.setenv("GATEWAY_ALLOW_UNKNOWN_HOST", "1")
    config = GatewayConfig.from_env(base_url="https://example.org/api/")
    assert config.base_url == "https://example.org/api"
