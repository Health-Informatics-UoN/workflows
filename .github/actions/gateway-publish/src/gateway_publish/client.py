"""HTTP client for the Gateway's team dataset API (/api/v{2,3}/teams/{teamId}/datasets).

Authenticates with a Private App's x-application-id / x-client-id headers. Updates go to
v3, because the v2 PUT overwrites the latest version in place instead of adding one. The
older /api/v1/integrations/datasets endpoints have been retired. See docs/gateway-notes.md.
"""

import json
import time
from dataclasses import dataclass
from typing import Any

import httpx

from gateway_publish.config import GatewayConfig

TIMEOUT = httpx.Timeout(60.0, connect=10.0)
# Reads are retried on 5xx and connection errors, waiting 2s then 4s. Writes are not: a
# retried update could add a second version.
READ_ATTEMPTS = 3
RETRY_WAIT = 2.0
STATUSES = ("ACTIVE", "DRAFT")


class GatewayError(Exception):
    def __init__(self, status_code: int, message: str, hint: str | None, body: Any):
        self.status_code = status_code
        self.message = message
        self.hint = hint
        self.body = body
        super().__init__(str(self))

    def __str__(self) -> str:
        text = f"HTTP {self.status_code}: {self.message}"
        if self.hint:
            text += f"\n  Likely cause: {self.hint}"
        return text


# (status code, substring of the response message, hint). First match wins; a None
# substring matches any message for that status.
ERROR_HINTS: list[tuple[int, str | None, str]] = [
    (400, "permissions do not allow", "the Private App lacks the permission for this action "
        "(datasets.create / datasets.update / datasets.delete). Fix on the app's Permissions tab."),
    (400, "not been enabled", "the Private App is disabled. Set it to Enabled on the App Info tab."),
    (400, "unknown format", "the metadata matched no supported schema. Run `gateway-publish validate` "
        "and see the TRASER details in the response."),
    (400, "Title is required", "summary.title is missing from the metadata."),
    (401, "No known integration", "GATEWAY_APP_ID does not match any app on this Gateway "
        "(wrong value, or credentials from a different environment)."),
    (401, "credentials provided are invalid", "GATEWAY_CLIENT_ID does not match the app."),
    (401, "another team", "the app belongs to a different team from GATEWAY_TEAM_ID or from the dataset."),
    (401, None, "credentials missing, wrong, or not valid for this team."),
    (404, None, "no dataset with that ID in this team (wrong ID or team, or it was deleted)."),
    (410, None, "this endpoint has been retired by the Gateway."),
    (500, None, "server error. For update/delete this can also mean the dataset ID does not exist."),
]


def _hint_for(status_code: int, message: str) -> str | None:
    for code, needle, hint in ERROR_HINTS:
        if code == status_code and (needle is None or needle.lower() in message.lower()):
            return hint
    if status_code >= 500:
        return "server error on the Gateway; retrying later may help."
    return None


def _raise_for_status(response: httpx.Response) -> None:
    if response.is_success:
        return
    try:
        body = response.json()
    except ValueError:
        body = response.text
    message = body.get("message", "") if isinstance(body, dict) else str(body)[:500]
    raise GatewayError(response.status_code, message, _hint_for(response.status_code, message), body)


@dataclass
class CreateResult:
    dataset_id: int
    version_id: int


@dataclass
class LatestVersion:
    version: int
    title: str | None
    metadata: dict[str, Any]


class GatewayClient:
    def __init__(self, config: GatewayConfig, transport: httpx.BaseTransport | None = None, sleep=time.sleep):
        self.config = config
        self._sleep = sleep
        self._http = httpx.Client(
            base_url=config.base_url,
            headers={
                "x-application-id": config.app_id.get_secret_value(),
                "x-client-id": config.client_id.get_secret_value(),
                "Accept": "application/json",
            },
            timeout=TIMEOUT,
            transport=transport,
        )

    def __enter__(self) -> "GatewayClient":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def close(self) -> None:
        self._http.close()

    def _datasets_path(self, api: str = "v2") -> str:
        return f"/{api}/teams/{self.config.team_id}/datasets"

    @staticmethod
    def _body(metadata: dict[str, Any], status: str, schema: tuple[str, str] | None = None) -> dict[str, Any]:
        # create_origin and status are read unconditionally by the Gateway; omitting
        # status on update would blank the dataset's status. DRAFT datasets are left out
        # of search, but the Gateway skips schema validation for them.
        if status not in STATUSES:
            raise ValueError(f"status must be one of {', '.join(STATUSES)}")
        if schema:
            # The envelope the Gateway's own form sends. Update passes schemaModel and
            # schemaVersion to TRASER; create records them as the version's source schema.
            metadata = {"metadata": metadata, "schemaModel": schema[0], "schemaVersion": schema[1]}
        return {"metadata": metadata, "create_origin": "API", "status": status}

    def create(
        self, metadata: dict[str, Any], *, status: str, schema: tuple[str, str] | None = None
    ) -> CreateResult:
        """Create a dataset. `schema` = (model, version) declares the input schema."""
        # Create only passes the query parameters to TRASER, not the envelope's schema.
        params = {"input_schema": schema[0], "input_version": schema[1]} if schema else None
        response = self._http.post(self._datasets_path(), params=params, json=self._body(metadata, status, schema))
        _raise_for_status(response)
        body = response.json()
        return CreateResult(dataset_id=int(body["data"]), version_id=int(body["version"]))

    def update(
        self, dataset_id: int, metadata: dict[str, Any], *, status: str, schema: tuple[str, str] | None = None
    ) -> dict[str, Any]:
        """Add a new version of the dataset (v3; the v2 PUT would overwrite the latest one)."""
        response = self._http.put(
            f"{self._datasets_path('v3')}/{dataset_id}", json=self._body(metadata, status, schema)
        )
        _raise_for_status(response)
        return response.json()

    def _read(self, path: str, params: dict[str, Any] | None = None) -> httpx.Response:
        for attempt in range(1, READ_ATTEMPTS + 1):
            try:
                response = self._http.get(path, params=params)
                if response.status_code < 500 or attempt == READ_ATTEMPTS:
                    return response
            except httpx.TransportError:
                if attempt == READ_ATTEMPTS:
                    raise
            self._sleep(RETRY_WAIT * 2 ** (attempt - 1))
        raise AssertionError("unreachable")

    def get(
        self,
        dataset_id: int,
        schema_model: str | None = None,
        schema_version: str | None = None,
    ) -> dict[str, Any]:
        if bool(schema_model) != bool(schema_version):
            raise ValueError("schema_model and schema_version must be given together")
        params = {"schema_model": schema_model, "schema_version": schema_version} if schema_model else None
        response = self._read(f"{self._datasets_path()}/{dataset_id}", params=params)
        _raise_for_status(response)
        return response.json()

    def delete(self, dataset_id: int) -> dict[str, Any]:
        response = self._http.delete(f"{self._datasets_path()}/{dataset_id}")
        _raise_for_status(response)
        return response.json()

    def list(self, status: str = "active", title: str | None = None) -> dict[str, Any]:
        """List the team's datasets. `title` is a substring match on the Gateway side."""
        params: dict[str, Any] = {"with_metadata": "false"}
        if title:
            params["title"] = title
        response = self._read(f"{self._datasets_path()}/status/{status}", params=params)
        _raise_for_status(response)
        return response.json()


def latest_version(get_response: dict[str, Any]) -> LatestVersion:
    """Pull the latest version number, title and stored metadata out of a GET response.

    The Gateway returns only the latest version in `data.versions`; its `metadata` may be
    a JSON string or an object, wrapping the GWDM document under a further `metadata` key.
    """
    versions = get_response["data"].get("versions") or []
    if not versions:
        raise ValueError("GET response contains no versions")
    latest = max(versions, key=lambda v: v.get("version", 0))
    stored = latest.get("metadata") or {}
    if isinstance(stored, str):
        stored = json.loads(stored)
    document = stored.get("metadata", stored)
    title = (document.get("summary") or {}).get("title") or latest.get("title")
    return LatestVersion(version=int(latest.get("version", 0)), title=title, metadata=document)
