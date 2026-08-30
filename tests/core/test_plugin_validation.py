"""Load-time plugin manifest and live configuration validation contracts."""

from __future__ import annotations

import logging

import pytest

from plugins.base import PluginManifest, PluginValidationError
from plugins.loader import PluginConfigError, _validate_plugin_config, load_plugins


def _write_plugin(plugin_dir, manifest_expression: str) -> None:
    plugin_dir.mkdir()
    (plugin_dir / "__init__.py").write_text(
        f"""\
from plugins.base import HexisPlugin, PluginManifest

class ValidationPlugin(HexisPlugin):
    @property
    def manifest(self):
        return {manifest_expression}

    def register(self, api):
        raise AssertionError("invalid plugin reached registration")

plugin = ValidationPlugin()
""",
        encoding="utf-8",
    )


@pytest.mark.parametrize(
    ("manifest", "message"),
    [
        ({"id": "Bad ID", "name": "Bad"}, "id must be"),
        ({"id": "valid", "name": ""}, "name must be"),
        ({"id": "valid", "name": "Valid", "version": "latest"}, "semantic versioning"),
        (
            {
                "id": "valid",
                "name": "Valid",
                "config_schema": {"type": "string"},
            },
            "root type must be 'object'",
        ),
    ],
)
def test_manifest_rejects_invalid_contracts(manifest, message):
    with pytest.raises(PluginValidationError, match=message):
        PluginManifest.from_dict(manifest)


def test_manifest_rejects_invalid_json_schema():
    with pytest.raises(PluginValidationError, match="not valid JSON Schema"):
        PluginManifest.from_dict(
            {
                "id": "invalid-schema",
                "name": "Invalid Schema",
                "config_schema": {
                    "type": "object",
                    "properties": {"token": {"type": "not-a-real-json-type"}},
                },
            }
        )


def test_live_plugin_config_reports_precise_schema_path():
    manifest = PluginManifest.from_dict(
        {
            "id": "weather",
            "name": "Weather",
            "config_schema": {
                "type": "object",
                "properties": {"api_key": {"type": "string", "minLength": 1}},
                "required": ["api_key"],
                "additionalProperties": False,
            },
        }
    )

    with pytest.raises(PluginConfigError, match="api_key.*is a required property"):
        _validate_plugin_config(manifest, {})
    with pytest.raises(PluginConfigError, match="unexpected.*was unexpected"):
        _validate_plugin_config(manifest, {"api_key": "test", "unexpected": True})


@pytest.mark.asyncio(loop_scope="session")
async def test_loader_skips_invalid_manifest_before_registration(tmp_path, caplog):
    plugin_dir = tmp_path / "invalid_manifest_plugin"
    _write_plugin(
        plugin_dir,
        'PluginManifest(id="Bad ID", name="Invalid", version="1.0.0")',
    )

    with caplog.at_level(logging.ERROR):
        registry = await load_plugins(object(), extra_dirs=[tmp_path], include_bundled=False)

    assert registry.plugin_count() == 0
    assert "invalid manifest" in caplog.text
    assert "invalid plugin reached registration" not in caplog.text


@pytest.mark.asyncio(loop_scope="session")
async def test_loader_skips_invalid_live_config_before_registration(
    monkeypatch, tmp_path, caplog
):
    plugin_dir = tmp_path / "invalid_config_plugin"
    _write_plugin(
        plugin_dir,
        "PluginManifest("
        'id="config-test", name="Config Test", version="1.0.0", '
        'config_schema={"type": "object", "required": ["token"], '
        '"properties": {"token": {"type": "string"}}})',
    )

    async def _missing_required_config(pool, plugin_id):
        return {}

    monkeypatch.setattr("plugins.loader._load_plugin_config", _missing_required_config)
    with caplog.at_level(logging.ERROR):
        registry = await load_plugins(object(), extra_dirs=[tmp_path], include_bundled=False)

    assert registry.plugin_count() == 0
    assert "invalid config plugin.config-test" in caplog.text
    assert "Correct or remove that config value" in caplog.text


@pytest.mark.asyncio(loop_scope="session")
async def test_loader_rejects_plugin_json_runtime_manifest_mismatch(tmp_path, caplog):
    plugin_dir = tmp_path / "manifest_mismatch_plugin"
    _write_plugin(
        plugin_dir,
        'PluginManifest(id="runtime-id", name="Runtime", version="1.0.0")',
    )
    (plugin_dir / "plugin.json").write_text(
        '{"id":"file-id","name":"File","version":"1.0.0"}',
        encoding="utf-8",
    )

    with caplog.at_level(logging.ERROR):
        registry = await load_plugins(object(), extra_dirs=[tmp_path], include_bundled=False)

    assert registry.plugin_count() == 0
    assert "plugin.json must exactly match" in caplog.text


@pytest.mark.asyncio(loop_scope="session")
async def test_loader_validates_plugin_json_before_import(tmp_path, caplog):
    plugin_dir = tmp_path / "preflight_plugin"
    plugin_dir.mkdir()
    imported_marker = tmp_path / "module-imported"
    (plugin_dir / "__init__.py").write_text(
        f"from pathlib import Path\nPath({str(imported_marker)!r}).write_text('yes')\n",
        encoding="utf-8",
    )
    (plugin_dir / "plugin.json").write_text(
        '{"id":"Bad ID","name":"Invalid","version":"1.0.0"}',
        encoding="utf-8",
    )

    with caplog.at_level(logging.ERROR):
        registry = await load_plugins(object(), extra_dirs=[tmp_path], include_bundled=False)

    assert registry.plugin_count() == 0
    assert "invalid plugin.json" in caplog.text
    assert not imported_marker.exists()
