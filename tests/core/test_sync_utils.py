import pytest

from core.sync_utils import run_sync

pytestmark = pytest.mark.core


def test_run_sync_runs_outside_loop():
    async def _demo():
        return "ok"

    assert run_sync(_demo()) == "ok"


@pytest.mark.asyncio(loop_scope="session")
async def test_run_sync_raises_inside_loop():
    async def _demo():
        return "ok"

    coro = _demo()
    try:
        with pytest.raises(RuntimeError):
            run_sync(coro)
    finally:
        coro.close()
