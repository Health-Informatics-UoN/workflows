"""Connection settings, read from the environment.

Credentials are held as SecretStr so they never appear in reprs, tracebacks or logs.
"""

import os
from urllib.parse import urlparse

from pydantic import BaseModel, SecretStr

DEFAULT_BASE_URL = "https://api.healthdatagateway.org/api"
KNOWN_HOSTS = {"api.healthdatagateway.org", "api.dev.hdruk.cloud"}


class ConfigError(Exception):
    pass


class GatewayConfig(BaseModel):
    base_url: str = DEFAULT_BASE_URL
    app_id: SecretStr
    client_id: SecretStr
    team_id: int

    @classmethod
    def from_env(cls, base_url: str | None = None, team_id: int | None = None) -> "GatewayConfig":
        missing = [
            name
            for name in ("GATEWAY_APP_ID", "GATEWAY_CLIENT_ID")
            if not os.environ.get(name)
        ]
        if team_id is None and not os.environ.get("GATEWAY_TEAM_ID"):
            missing.append("GATEWAY_TEAM_ID")
        if missing:
            raise ConfigError(
                f"Missing environment variable(s): {', '.join(missing)}. "
                "App ID and Client ID come from the Private App's Authentication tab "
                "(Integrations > API Management > Manage API); the team ID is the "
                "Gateway team that owns the app."
            )

        try:
            resolved_team_id = team_id if team_id is not None else int(os.environ["GATEWAY_TEAM_ID"])
        except ValueError:
            raise ConfigError("GATEWAY_TEAM_ID must be an integer") from None

        config = cls(
            base_url=(base_url or os.environ.get("GATEWAY_BASE_URL") or DEFAULT_BASE_URL).rstrip("/"),
            app_id=SecretStr(os.environ["GATEWAY_APP_ID"]),
            client_id=SecretStr(os.environ["GATEWAY_CLIENT_ID"]),
            team_id=resolved_team_id,
        )
        config.check_target_allowed()
        return config

    def check_target_allowed(self) -> None:
        """Refuse to send credentials to an unknown host unless explicitly opted in."""
        host = urlparse(self.base_url).hostname
        if host not in KNOWN_HOSTS and os.environ.get("GATEWAY_ALLOW_UNKNOWN_HOST") != "1":
            raise ConfigError(
                f"Refusing to send credentials to unknown host {host} "
                f"(known: {', '.join(sorted(KNOWN_HOSTS))}). Set GATEWAY_ALLOW_UNKNOWN_HOST=1 to override."
            )
