from __future__ import annotations

import asyncio
from typing import Any, Awaitable


def run_sync(awaitable: Awaitable[Any]) -> Any:
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(awaitable)
    raise RuntimeError("Sync wrapper cannot run inside an active event loop.")
