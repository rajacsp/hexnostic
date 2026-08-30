"""
Hexis Channel System - Streaming Response Coalescer

Provides progressive edit-in-place delivery for channels that support
message editing. Tokens are buffered and coalesced into periodic edits
to avoid rate-limit issues while maintaining a responsive feel.

Channels that don't support editing fall back to chunked send.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .base import ChannelAdapter


@dataclass
class StreamConfig:
    """Tuning parameters for stream coalescing."""

    min_chars: int = 40       # Minimum chars before first visible send
    max_chars: int = 500      # Force an edit after accumulating this many chars since last edit
    idle_ms: int = 300        # Minimum ms between edits (rate-limit guard)
    final_delay_ms: int = 100 # Small delay before the final edit


class StreamCoalescer:
    """
    Buffers streaming tokens and progressively edits a message in-channel.

    Usage:
        coalescer = StreamCoalescer(adapter, channel_id, ...)
        for token in stream:
            await coalescer.push(token)
        message_id = await coalescer.flush()
    """

    def __init__(
        self,
        adapter: ChannelAdapter,
        channel_id: str,
        *,
        reply_to: str | None = None,
        thread_id: str | None = None,
        config: StreamConfig | None = None,
    ) -> None:
        self._adapter = adapter
        self._channel_id = channel_id
        self._reply_to = reply_to
        self._thread_id = thread_id
        self._config = config or StreamConfig()

        self._buffer: list[str] = []
        self._message_id: str | None = None
        self._last_edit_time: float = 0
        self._chars_since_edit: int = 0
        self._total_text: str = ""

    @property
    def message_id(self) -> str | None:
        return self._message_id

    async def push(self, token: str) -> None:
        """Push a token into the buffer, flushing to channel as needed."""
        self._buffer.append(token)
        self._total_text += token
        self._chars_since_edit += len(token)

        # First message: wait for min_chars before sending
        if self._message_id is None:
            if len(self._total_text) >= self._config.min_chars:
                await self._send_initial()
            return

        # Subsequent edits: respect rate limits and char thresholds
        now = time.monotonic()
        elapsed_ms = (now - self._last_edit_time) * 1000

        if (
            self._chars_since_edit >= self._config.max_chars
            and elapsed_ms >= self._config.idle_ms
        ):
            await self._edit_current()

    async def flush(self) -> str | None:
        """
        Final flush — send or edit with the complete text.

        Returns the platform message ID.
        """
        if not self._total_text:
            return None

        if self._message_id is None:
            # Never sent — send the whole thing as one message
            self._message_id = await self._adapter.send(
                self._channel_id,
                self._total_text,
                reply_to=self._reply_to,
                thread_id=self._thread_id,
            )
        else:
            # Small delay to let the user see the "typing" animation
            if self._config.final_delay_ms > 0:
                await asyncio.sleep(self._config.final_delay_ms / 1000)
            await self._edit_current()

        return self._message_id

    async def _send_initial(self) -> None:
        """Send the first message."""
        self._message_id = await self._adapter.send(
            self._channel_id,
            self._total_text,
            reply_to=self._reply_to,
            thread_id=self._thread_id,
        )
        self._last_edit_time = time.monotonic()
        self._chars_since_edit = 0
        self._buffer.clear()

    async def _edit_current(self) -> None:
        """Edit the existing message with accumulated text."""
        if not self._message_id:
            return
        try:
            await self._adapter.edit_message(
                self._channel_id,
                self._message_id,
                self._total_text,
            )
        except Exception:
            pass  # Non-fatal — message may still show partial content
        self._last_edit_time = time.monotonic()
        self._chars_since_edit = 0
        self._buffer.clear()
