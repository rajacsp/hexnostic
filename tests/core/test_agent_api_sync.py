import pytest

from core import agent_api
from tests.utils import _db_dsn

pytestmark = pytest.mark.core


def test_get_agent_status_sync():
    status = agent_api.get_agent_status_sync(_db_dsn())
    assert "configured" in status
    assert "consent_status" in status


def test_get_init_defaults_sync():
    defaults = agent_api.get_init_defaults_sync(_db_dsn())
    assert defaults["heartbeat_interval_minutes"] > 0
