"""Check metadata with TRASER, HDR UK's translation service, the way the Gateway does.

On create/update (non-draft) the Gateway POSTs {"metadata": ..., "extra": {...}} to TRASER's
/translate, asking for GWDM output with input and output validation on. Reproducing that call
catches problems the plain /validate endpoint would miss, such as a translation that produces
invalid GWDM. The dev TRASER is used; the live Gateway's own instance may differ.
"""

import os
from typing import Any

import httpx

DEFAULT_TRASER_URL = "https://hdr-gateway-traser-dev-qmnkcg5qjq-ew.a.run.app"
# What the live Gateway stores (dataset_versions.gwdm_version, observed 2026-11-20); the
# code default is 2.0, which drops HDRUK 4.1.0-only fields.
GWDM_VERSION = "2.2"
# Mirrors the `extra` block the Gateway adds (MetadataOnboard::metadataOnboard).
EXTRA = {
    "id": "placeholder",
    "pid": "placeholder",
    "datasetType": "Health and disease",
    "publisherId": "placeholder",
    "publisherName": "placeholder",
}


class TraserError(Exception):
    pass


def _format_errors(errors: Any) -> list[str]:
    if not isinstance(errors, list):
        return [str(errors)]
    return [
        f"{e.get('instancePath') or '/'}: {e.get('message')} {e.get('params') or ''}".rstrip()
        if isinstance(e, dict) else str(e)
        for e in errors
    ]


def traser_errors(
    metadata: dict[str, Any],
    version: str,
    model: str = "HDRUK",
    base_url: str | None = None,
    transport: httpx.BaseTransport | None = None,
) -> list[str]:
    """Return readable errors from TRASER's /translate to GWDM, empty if it succeeds."""
    url = base_url or os.environ.get("TRASER_URL") or DEFAULT_TRASER_URL
    with httpx.Client(base_url=url, timeout=120, transport=transport) as client:
        try:
            response = client.post(
                "/translate",
                params={
                    "input_schema": model,
                    "input_version": version,
                    "output_schema": "GWDM",
                    "output_version": GWDM_VERSION,
                    "validate_input": "1",
                    "validate_output": "1",
                },
                json={"metadata": metadata, "extra": EXTRA},
            )
        except httpx.HTTPError as e:
            raise TraserError(f"Could not reach TRASER at {url}: {e}") from None

    if response.is_success:
        return []
    try:
        body = response.json()
    except ValueError:
        raise TraserError(f"TRASER returned HTTP {response.status_code}: {response.text[:300]}") from None
    if response.status_code != 400:
        raise TraserError(f"TRASER returned HTTP {response.status_code}: {body}")

    message = body.get("message", "")
    details = body.get("details")
    if isinstance(details, dict) and "validationErrors" in details:
        details = details["validationErrors"]
    return [f"{message}:"] + [f"  {line}" for line in _format_errors(details)]
