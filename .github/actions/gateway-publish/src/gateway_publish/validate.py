"""Offline validation against the HDR UK schemas bundled from HDRUK/schemata-2."""

import json
from collections.abc import Iterator
from importlib import resources
from typing import Any

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

DEFAULT_MODEL = "HDRUK"


def available_versions(model: str = DEFAULT_MODEL) -> list[str]:
    root = resources.files("gateway_publish").joinpath("schemas", model)
    return sorted(p.name for p in root.iterdir() if p.is_dir())


def load_schema(version: str, model: str = DEFAULT_MODEL) -> dict[str, Any]:
    path = resources.files("gateway_publish").joinpath("schemas", model, version, "schema.json")
    if not path.is_file():
        raise ValueError(
            f"No bundled schema for {model} {version}; available: {', '.join(available_versions(model))}"
        )
    return json.loads(path.read_text())


def validation_errors(metadata: dict[str, Any], version: str, model: str = DEFAULT_MODEL) -> list[str]:
    """Return readable error messages, empty if the metadata is valid."""
    validator = Draft202012Validator(load_schema(version, model))
    messages: list[str] = []
    for error in sorted(validator.iter_errors(metadata), key=lambda e: list(map(str, e.absolute_path))):
        for leaf in _specific_errors(error):
            message = f"/{'/'.join(str(p) for p in leaf.absolute_path)}: {leaf.message}"
            if message not in messages:
                messages.append(message)
    return messages


def _leaves(error: ValidationError) -> Iterator[ValidationError]:
    if error.context:
        for child in error.context:
            yield from _leaves(child)
    else:
        yield error


def _specific_errors(error: ValidationError) -> list[ValidationError]:
    """The deepest failures inside nested anyOfs, rather than "<whole object> is not valid".

    The schemas wrap most fields in anyOf[<type>, null], so the "is not of type 'null'"
    branch failures are noise whenever another branch explains the problem.
    """
    leaves = [e for e in _leaves(error) if not (e.validator == "type" and e.validator_value == "null")]
    if not leaves:
        return [error]
    depth = max(len(e.absolute_path) for e in leaves)
    return [e for e in leaves if len(e.absolute_path) == depth]
