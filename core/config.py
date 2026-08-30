"""
Hexis Configuration File Support

Supplements environment variables with a config file at:
  ~/.hexis/config.json                          (global)
  ~/.hexis/instances/<name>/config.json         (per-instance)

Precedence: env vars > config file > defaults
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Default base directory
_HEXIS_HOME = Path(os.environ.get("HEXIS_HOME", Path.home() / ".hexis"))

# Defaults used when neither env var nor config file provides a value
_DEFAULTS: dict[str, Any] = {
    "embedding.service_url": "http://localhost:42666/api/embed",
    "embedding.model_id": "embeddinggemma:300m-qat-q4_0",
    "embedding.dimension": 768,
    "heartbeat.interval_minutes": 60,
    "heartbeat.max_energy": 20,
    "heartbeat.base_regeneration": 10,
    "heartbeat.timezone": "UTC",
    "maintenance.interval_seconds": 60,
    "db.host": "localhost",
    "db.port": 43815,
    "db.name": "hexis_memory",
    "db.user": "hexis_user",
    "db.password_env": "POSTGRES_PASSWORD",
}

# Mapping from flat config keys to environment variable names
_ENV_MAP: dict[str, str] = {
    "embedding.service_url": "EMBEDDING_SERVICE_URL",
    "embedding.model_id": "EMBEDDING_MODEL_ID",
    "embedding.dimension": "EMBEDDING_DIMENSION",
    "heartbeat.interval_minutes": "HEARTBEAT_INTERVAL_MINUTES",
    "heartbeat.max_energy": "HEARTBEAT_MAX_ENERGY",
    "heartbeat.timezone": "HEARTBEAT_TIMEZONE",
    "heartbeat.active_hours": "HEARTBEAT_ACTIVE_HOURS",
    "db.host": "POSTGRES_HOST",
    "db.port": "POSTGRES_PORT",
    "db.name": "POSTGRES_DB",
    "db.user": "POSTGRES_USER",
    "db.password_env": "POSTGRES_PASSWORD_ENV",
}


def hexis_home() -> Path:
    """Return the Hexis home directory (~/.hexis)."""
    return _HEXIS_HOME


def _config_file_path(instance: str | None = None) -> Path:
    """Return the path to the config file for the given instance."""
    if instance and instance != "default":
        return _HEXIS_HOME / "instances" / instance / "config.json"
    return _HEXIS_HOME / "config.json"


def _load_file(path: Path) -> dict[str, Any]:
    """Load a JSON config file, returning empty dict if not found."""
    if not path.exists():
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            logger.warning("Config file %s is not a JSON object, ignoring", path)
            return {}
        return data
    except (json.JSONDecodeError, OSError) as exc:
        logger.warning("Failed to load config file %s: %s", path, exc)
        return {}


def _flatten(data: dict[str, Any], prefix: str = "") -> dict[str, Any]:
    """Flatten a nested dict into dot-separated keys."""
    result: dict[str, Any] = {}
    for key, value in data.items():
        full_key = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            result.update(_flatten(value, full_key))
        else:
            result[full_key] = value
    return result


def _unflatten(flat: dict[str, Any]) -> dict[str, Any]:
    """Convert dot-separated keys back to a nested dict."""
    result: dict[str, Any] = {}
    for key, value in flat.items():
        parts = key.split(".")
        d = result
        for part in parts[:-1]:
            d = d.setdefault(part, {})
        d[parts[-1]] = value
    return result


class HexisConfig:
    """
    Read-only configuration with env var > file > defaults precedence.

    Usage:
        config = HexisConfig.load()
        url = config.get("embedding.service_url")
        interval = config.get_int("heartbeat.interval_minutes")
    """

    def __init__(
        self,
        file_values: dict[str, Any],
        instance: str | None = None,
    ):
        self._file = file_values
        self._instance = instance

    @classmethod
    def load(cls, instance: str | None = None) -> "HexisConfig":
        """Load configuration from the config file."""
        # Load global config
        global_values = _flatten(_load_file(_config_file_path(None)))

        # Overlay instance-specific config
        if instance and instance != "default":
            instance_values = _flatten(_load_file(_config_file_path(instance)))
            global_values.update(instance_values)

        return cls(global_values, instance)

    def get(self, key: str, default: Any = None) -> Any:
        """
        Get a config value with precedence: env var > config file > default.
        """
        # 1. Check env var
        env_name = _ENV_MAP.get(key)
        if env_name:
            env_val = os.environ.get(env_name)
            if env_val is not None:
                return env_val

        # 2. Check config file
        if key in self._file:
            return self._file[key]

        # 3. Check built-in defaults
        if key in _DEFAULTS:
            return _DEFAULTS[key]

        return default

    def get_int(self, key: str, default: int = 0) -> int:
        """Get a config value as an integer."""
        val = self.get(key)
        if val is None:
            return default
        try:
            return int(val)
        except (ValueError, TypeError):
            return default

    def get_float(self, key: str, default: float = 0.0) -> float:
        """Get a config value as a float."""
        val = self.get(key)
        if val is None:
            return default
        try:
            return float(val)
        except (ValueError, TypeError):
            return default

    def get_bool(self, key: str, default: bool = False) -> bool:
        """Get a config value as a boolean."""
        val = self.get(key)
        if val is None:
            return default
        if isinstance(val, bool):
            return val
        if isinstance(val, str):
            return val.lower() in ("true", "1", "yes")
        return bool(val)

    def get_list(self, key: str, default: list | None = None) -> list:
        """Get a config value as a list."""
        val = self.get(key)
        if val is None:
            return default or []
        if isinstance(val, list):
            return val
        if isinstance(val, str):
            return [x.strip() for x in val.split(",") if x.strip()]
        return default or []

    def section(self, prefix: str) -> dict[str, Any]:
        """Get all values under a prefix as a dict."""
        result: dict[str, Any] = {}
        prefix_dot = prefix if prefix.endswith(".") else prefix + "."
        for key, value in self._file.items():
            if key.startswith(prefix_dot):
                result[key[len(prefix_dot):]] = value
        return result

    def to_dict(self) -> dict[str, Any]:
        """Return the full resolved config as a nested dict."""
        merged: dict[str, Any] = {}
        merged.update(_DEFAULTS)
        merged.update(self._file)
        # Overlay env vars
        for key, env_name in _ENV_MAP.items():
            env_val = os.environ.get(env_name)
            if env_val is not None:
                merged[key] = env_val
        return _unflatten(merged)

    @property
    def file_path(self) -> Path:
        """Path to the config file that was loaded."""
        return _config_file_path(self._instance)


def save_config(
    data: dict[str, Any],
    instance: str | None = None,
) -> Path:
    """Save a configuration dict to the config file."""
    path = _config_file_path(instance)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    return path


def init_config_file(instance: str | None = None) -> Path:
    """Create a config file with defaults if it doesn't exist."""
    path = _config_file_path(instance)
    if path.exists():
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    defaults = _unflatten(_DEFAULTS)
    with open(path, "w") as f:
        json.dump(defaults, f, indent=2)
    logger.info("Created default config file: %s", path)
    return path
