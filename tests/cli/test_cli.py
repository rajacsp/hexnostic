import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

from core.instance import InstanceRegistry

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.cli]


# Instance CLI tests

@pytest.fixture
def temp_hexis_dir(tmp_path):
    """Create a temporary .hexis directory for instance tests."""
    hexis_dir = tmp_path / ".hexis"
    hexis_dir.mkdir()
    return hexis_dir


async def test_cli_instance_list_empty(temp_hexis_dir):
    """Test listing instances when none exist."""
    env = os.environ.copy()
    with patch.object(InstanceRegistry, "CONFIG_DIR", temp_hexis_dir):
        with patch.object(InstanceRegistry, "CONFIG_FILE", temp_hexis_dir / "instances.json"):
            p = subprocess.run(
                [sys.executable, "-m", "apps.hexis_cli", "instance", "list"],
                capture_output=True,
                text=True,
                env=env,
                cwd=str(Path(__file__).resolve().parents[1]),
            )
    assert p.returncode == 0
    assert "No instances" in p.stdout or p.stdout.strip() == ""


async def test_cli_instance_current_none(temp_hexis_dir):
    """Test showing current instance when none is set."""
    env = os.environ.copy()
    with patch.object(InstanceRegistry, "CONFIG_DIR", temp_hexis_dir):
        with patch.object(InstanceRegistry, "CONFIG_FILE", temp_hexis_dir / "instances.json"):
            p = subprocess.run(
                [sys.executable, "-m", "apps.hexis_cli", "instance", "current"],
                capture_output=True,
                text=True,
                env=env,
                cwd=str(Path(__file__).resolve().parents[1]),
            )
    assert p.returncode == 0


async def test_cli_instance_use_nonexistent():
    """Test switching to a nonexistent instance fails."""
    env = os.environ.copy()
    p = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "instance", "use", "nonexistent-instance-xyz"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert p.returncode != 0


# Consent CLI tests

async def test_cli_consents_list(temp_hexis_dir):
    """`hexis consents` (DB-backed) lists recorded consent and exits 0."""
    env = os.environ.copy()
    p = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "consents"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert p.returncode == 0


async def test_cli_consents_show_nonexistent(temp_hexis_dir):
    """`hexis consents show` for an unrecorded model errors clearly."""
    env = os.environ.copy()
    p = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "consents", "show", "anthropic/nonexistent"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert p.returncode != 0 or "no consent" in p.stderr.lower()


# Original tests


async def test_cli_status_json_no_docker(db_pool):
    env = os.environ.copy()
    p = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "status", "--json", "--no-docker", "--wait-seconds", "60"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert p.returncode == 0, p.stderr
    data = json.loads(p.stdout)
    # Rich status (default) includes instance and memories
    assert "instance" in data
    assert "memories" in data


async def test_cli_status_raw_json_no_docker(db_pool):
    """Test legacy raw status format."""
    env = os.environ.copy()
    p = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "status", "--json", "--no-docker", "--raw", "--wait-seconds", "60"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert p.returncode == 0, p.stderr
    data = json.loads(p.stdout)
    assert "agent_configured" in data
    assert "pending_external_calls" in data


async def test_cli_demo_and_maturity_json(db_pool):
    env = os.environ.copy()
    command = [sys.executable, "-m", "apps.hexis_cli"]
    cwd = str(Path(__file__).resolve().parents[1])

    demo = subprocess.run(
        command + ["demo", "--json", "--wait-seconds", "60"],
        capture_output=True,
        text=True,
        env=env,
        cwd=cwd,
    )
    assert demo.returncode == 0, demo.stderr + demo.stdout
    demo_result = json.loads(demo.stdout)
    assert demo_result["ok"] is True
    assert demo_result["mode"] == "rollback_only"
    assert demo_result["passed"] == demo_result["total"] == 6

    maturity = subprocess.run(
        command + ["maturity", "--json", "--wait-seconds", "60"],
        capture_output=True,
        text=True,
        env=env,
        cwd=cwd,
    )
    assert maturity.returncode == 0, maturity.stderr
    maturity_result = json.loads(maturity.stdout)
    assert maturity_result["max_points"] == 20
    assert len(maturity_result["scenarios"]) == 5


async def test_cli_config_show_and_validate(db_pool):
    env = os.environ.copy()

    show = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "config", "show", "--json", "--wait-seconds", "60"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert show.returncode == 0, show.stderr
    cfg = json.loads(show.stdout)
    assert "agent.is_configured" in cfg

    validate = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "config", "validate", "--wait-seconds", "60"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert validate.returncode == 0, validate.stderr


async def test_cli_skill_improvement_opt_in_status_and_disable(db_pool):
    env = os.environ.copy()
    command = [sys.executable, "-m", "apps.hexis_cli"]
    cwd = str(Path(__file__).resolve().parents[1])
    try:
        disabled = subprocess.run(
            command + ["skills", "disable", "--wait-seconds", "60"],
            capture_output=True, text=True, env=env, cwd=cwd,
        )
        assert disabled.returncode == 0, disabled.stderr

        status = subprocess.run(
            command + ["skills", "--json", "--wait-seconds", "60"],
            capture_output=True, text=True, env=env, cwd=cwd,
        )
        assert status.returncode == 0, status.stderr
        assert json.loads(status.stdout)["enabled"] is False

        enabled = subprocess.run(
            command + ["skills", "enable", "--yes", "--wait-seconds", "60"],
            capture_output=True, text=True, env=env, cwd=cwd,
        )
        assert enabled.returncode == 0, enabled.stderr
        assert "never applies a skill automatically" in enabled.stdout

        proposals = subprocess.run(
            command + ["skills", "proposals", "--json", "--wait-seconds", "60"],
            capture_output=True, text=True, env=env, cwd=cwd,
        )
        assert proposals.returncode == 0, proposals.stderr
        assert isinstance(json.loads(proposals.stdout), list)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute(
                "SELECT set_config('skills.self_improvement.enabled', 'false'::jsonb)"
            )


async def test_cli_config_validate_fails_when_unconfigured(db_pool):
    async with db_pool.acquire() as conn:
        await conn.execute("SELECT set_config('agent.is_configured', 'false'::jsonb)")
    try:
        env = os.environ.copy()
        validate = subprocess.run(
            [sys.executable, "-m", "apps.hexis_cli", "config", "validate", "--wait-seconds", "60"],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(Path(__file__).resolve().parents[1]),
        )
        assert validate.returncode != 0
        assert "agent.is_configured is not true" in (validate.stderr + validate.stdout)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("SELECT set_config('agent.is_configured', 'true'::jsonb)")


async def test_cli_version():
    """Test --version flag outputs version string."""
    env = os.environ.copy()
    p = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "--version"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert p.returncode == 0
    assert "hexis" in p.stdout.lower()


async def test_cli_help_grouped():
    """Test grouped help output contains group names."""
    env = os.environ.copy()
    p = subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", "help"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[1]),
    )
    assert p.returncode == 0
    combined = p.stdout + p.stderr
    assert "Getting Started" in combined
    assert "Stack" in combined
    assert "Interact" in combined
    assert "Memory & Goals" in combined
    assert "Instances" in combined
