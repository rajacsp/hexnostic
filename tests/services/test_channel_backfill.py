from __future__ import annotations

import json

import pytest

from services import channel_backfill
from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def _snapshot_config(db_pool, keys: list[str]) -> dict[str, str]:
    async with db_pool.acquire() as conn:
        rows = await conn.fetch("SELECT key, value FROM config WHERE key = ANY($1::text[])", keys)
    return {row["key"]: json.dumps(_j(row["value"])) for row in rows}


async def _restore_config(db_pool, keys: list[str], snapshot: dict[str, str]) -> None:
    async with db_pool.acquire() as conn:
        for key in keys:
            if key in snapshot:
                await conn.execute("SELECT set_config($1, $2::jsonb)", key, snapshot[key])
            else:
                await conn.execute("DELETE FROM config WHERE key = $1", key)


async def _connected_channel(
    conn,
    connector_id: str,
    marker: str,
    account_key: str,
    capabilities: list[str] | None = None,
) -> None:
    capability_json = json.dumps(capabilities or ["live_chat", "send", "ingest_live"])
    attempt = _j(await conn.fetchval(
        """
        SELECT start_connection_attempt(
            $1,
            $3::jsonb,
            ARRAY[]::text[],
            '{}'::jsonb,
            NULL,
            NULL,
            'test',
            $2,
            CURRENT_TIMESTAMP + INTERVAL '10 minutes'
        )
        """,
        connector_id,
        marker,
        capability_json,
    ))
    await conn.fetchval(
        """
        SELECT complete_connection_attempt(
            $1::uuid,
            $2,
            $3,
            $4,
            ARRAY[]::text[],
            $5::jsonb,
            '{"test": true}'::jsonb
        )
        """,
        attempt["attempt_id"],
        account_key,
        connector_id,
        f"config:channel.{connector_id}",
        capability_json,
    )


async def test_slack_backfill_stores_history_as_connector_source_items(db_pool, monkeypatch):
    marker = get_test_identifier("slack-backfill")
    channel_id = f"C{marker.replace('-', '')[:10].upper()}"
    account = f"channel:slack:{marker}"
    token_env = f"HEXIS_TEST_SLACK_TOKEN_{marker.upper().replace('-', '_')}"
    monkeypatch.setenv(token_env, "xoxb-test-token-that-is-long-enough")
    config_keys = ["channel.slack.bot_token", "channel.slack.allowed_channels"]
    config_snapshot = await _snapshot_config(db_pool, config_keys)

    try:
        async with db_pool.acquire() as conn:
            await conn.execute("SELECT set_config('channel.slack.bot_token', $1::jsonb)", json.dumps(token_env))
            await conn.execute(
                "SELECT set_config('channel.slack.allowed_channels', $1::jsonb)",
                json.dumps([channel_id]),
            )
            await _connected_channel(conn, "slack", marker, account)
            queued = _j(await conn.fetchval(
                """
                SELECT enqueue_connector_backfill_job(
                    'slack',
                    $1,
                    'messages',
                    $2::jsonb,
                    '{"test": true}'::jsonb
                )
                """,
                account,
                json.dumps({"channel_id": channel_id, "max_messages": 2, "page_size": 2}),
            ))
            job = dict(await conn.fetchrow("SELECT * FROM connector_backfill_jobs WHERE id = $1::uuid", queued["job_id"]))

        async def fake_slack_get(token, path, *, params=None):
            assert token == "xoxb-test-token-that-is-long-enough"
            assert path == "/conversations.history"
            assert params["channel"] == channel_id
            assert params["limit"] == 2
            return {
                "ok": True,
                "messages": [
                    {"ts": "1710000000.000100", "user": "U1", "text": f"I prefer quiet planning {marker}."},
                    {"ts": "1710000001.000200", "user": "U2", "text": "The deadline is due today."},
                ],
                "response_metadata": {"next_cursor": "next-cursor"},
            }

        monkeypatch.setattr(channel_backfill, "_slack_get", fake_slack_get)
        result = await channel_backfill.process_slack_backfill_job(db_pool, job)

        async with db_pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT provider_item_id, source_document_id, ingestion_job_id, sensitivity
                FROM connector_source_items
                WHERE account_key = $1
                ORDER BY provider_item_id
                """,
                account,
            )
            opened = _j(await conn.fetchval("SELECT open_source_document($1::uuid)", rows[0]["source_document_id"]))

        assert result["status"] == "completed"
        assert result["result"]["items_stored"] == 2
        assert result["result"]["truncated"] is True
        assert [row["provider_item_id"] for row in rows] == [
            f"{channel_id}:1710000000.000100",
            f"{channel_id}:1710000001.000200",
        ]
        assert rows[0]["ingestion_job_id"] is not None
        assert rows[0]["sensitivity"] == "shared"
        assert f"I prefer quiet planning {marker}." in opened["content"]
        assert opened["source_attribution"]["connector_id"] == "slack"
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM connector_backfill_jobs WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connector_sync_cursors WHERE account_key = $1", account)
            await conn.execute("DELETE FROM integration_connections WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connection_attempts WHERE source_session_id = $1", marker)
            await conn.execute(
                "DELETE FROM source_documents WHERE path LIKE $1",
                f"slack://{account}/message/{channel_id}:%",
            )
            await conn.execute(
                "DELETE FROM ingestion_jobs WHERE content LIKE $1",
                f"%{marker}%",
            )
        await _restore_config(db_pool, config_keys, config_snapshot)


async def test_telegram_backfill_fails_loudly_with_provider_limitation(db_pool):
    marker = get_test_identifier("telegram-backfill")
    account = f"channel:telegram:{marker}"

    try:
        async with db_pool.acquire() as conn:
            await _connected_channel(conn, "telegram", marker, account)
            queued = _j(await conn.fetchval(
                """
                SELECT enqueue_connector_backfill_job(
                    'telegram',
                    $1,
                    'messages',
                    '{}'::jsonb,
                    '{"test": true}'::jsonb,
                    1
                )
                """,
                account,
            ))
            claimed = _j(await conn.fetchval(
                "SELECT claim_connector_backfill_jobs_for('telegram', 1)"
            ))
            job = claimed[0]

        result = await channel_backfill.process_channel_backfill_job(db_pool, job)

        assert result["status"] == "failed"
        async with db_pool.acquire() as conn:
            error = await conn.fetchval(
                "SELECT error FROM connector_backfill_jobs WHERE id = $1::uuid",
                queued["job_id"],
            )
        assert "cannot retroactively fetch chat history" in error
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM connector_backfill_jobs WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connector_sync_cursors WHERE account_key = $1", account)
            await conn.execute("DELETE FROM integration_connections WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connection_attempts WHERE source_session_id = $1", marker)


async def test_telegram_export_backfill_imports_local_history(db_pool, tmp_path):
    marker = get_test_identifier("telegram-export")
    account = f"channel:telegram:{marker}"
    export_path = tmp_path / "telegram-result.json"
    export_path.write_text(
        json.dumps(
            {
                "name": f"Chat {marker}",
                "messages": [
                    {
                        "id": 1,
                        "type": "message",
                        "date": "2026-07-20T10:00:00+00:00",
                        "from": "Eric",
                        "text": f"Please remember the project marker {marker}.",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    try:
        async with db_pool.acquire() as conn:
            await _connected_channel(conn, "telegram", marker, account)
            queued = _j(await conn.fetchval(
                """
                SELECT enqueue_connector_backfill_job(
                    'telegram',
                    $1,
                    'messages',
                    $2::jsonb,
                    '{"test": true}'::jsonb,
                    3
                )
                """,
                account,
                json.dumps({"export_path": str(export_path), "max_messages": 10}),
            ))
            claimed = _j(await conn.fetchval(
                "SELECT claim_connector_backfill_jobs_for('telegram', 1)"
            ))
            job = claimed[0]

        result = await channel_backfill.process_channel_backfill_job(db_pool, job)

        async with db_pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT provider_item_id, source_document_id, sensitivity
                FROM connector_source_items
                WHERE account_key = $1
                ORDER BY provider_item_id
                """,
                account,
            )
            opened = _j(await conn.fetchval("SELECT open_source_document($1::uuid)", rows[0]["source_document_id"]))

        assert result["status"] == "completed"
        assert result["result"]["items_stored"] == 1
        assert rows[0]["sensitivity"] == "private"
        assert marker in opened["content"]
        assert queued["estimate"]["provider_status"] == "local_export_import"
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM connector_backfill_jobs WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connector_sync_cursors WHERE account_key = $1", account)
            await conn.execute("DELETE FROM integration_connections WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connection_attempts WHERE source_session_id = $1", marker)
            await conn.execute(
                "DELETE FROM source_documents WHERE path LIKE $1",
                f"telegram://{account}/message/%",
            )


async def test_twitter_archive_backfill_imports_tweets_and_dms(db_pool, tmp_path):
    marker = get_test_identifier("twitter-archive")
    account = f"archive:twitter_x:{marker}"
    archive_dir = tmp_path / "twitter-archive"
    data_dir = archive_dir / "data"
    data_dir.mkdir(parents=True)
    tweet_js = data_dir / "tweet.js"
    dm_js = data_dir / "direct-message.js"
    tweet_js.write_text(
        "window.YTD.tweets.part0 = "
        + json.dumps([
            {
                "tweet": {
                    "id_str": f"tweet-{marker}",
                    "created_at": "Mon Jul 20 10:00:00 +0000 2026",
                    "full_text": f"I want Samantha to remember Twitter archive marker {marker}.",
                    "entities": {"user_mentions": [{"screen_name": "QuixiAI"}]},
                }
            }
        ])
        + ";",
        encoding="utf-8",
    )
    dm_js.write_text(
        "window.YTD.direct_messages.part0 = "
        + json.dumps([
            {
                "dmConversation": {
                    "conversationId": f"dm-{marker}",
                    "messages": [
                        {
                            "messageCreate": {
                                "id": f"dm-message-{marker}",
                                "senderId": "eric",
                                "recipientId": "friend",
                                "createdAt": "2026-07-20T11:00:00.000Z",
                                "text": f"Private Twitter/X DM marker {marker}.",
                            }
                        }
                    ],
                }
            }
        ])
        + ";",
        encoding="utf-8",
    )

    try:
        async with db_pool.acquire() as conn:
            await _connected_channel(conn, "twitter_x", marker, account, capabilities=["ingest"])
            queued = _j(await conn.fetchval(
                """
                SELECT enqueue_connector_backfill_job(
                    'twitter_x',
                    $1,
                    'messages',
                    $2::jsonb,
                    '{"test": true}'::jsonb,
                    3
                )
                """,
                account,
                json.dumps({"export_path": str(archive_dir), "max_messages": 10}),
            ))
            claimed = _j(await conn.fetchval(
                "SELECT claim_connector_backfill_jobs_for('twitter_x', 1)"
            ))
            job = claimed[0]

        result = await channel_backfill.process_channel_backfill_job(db_pool, job)

        async with db_pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT provider_item_id, item_kind, source_document_id, sensitivity
                FROM connector_source_items
                WHERE account_key = $1
                ORDER BY provider_item_id
                """,
                account,
            )
            opened = [
                _j(await conn.fetchval("SELECT open_source_document($1::uuid)", row["source_document_id"]))
                for row in rows
            ]

        assert result["status"] == "completed"
        assert result["result"]["items_stored"] == 2
        assert queued["estimate"]["provider_status"] == "local_archive_import"
        assert {row["provider_item_id"] for row in rows} == {
            f"tweet:tweet-{marker}",
            f"dm:dm-{marker}:dm-message-{marker}",
        }
        sensitivity_by_id = {row["provider_item_id"]: row["sensitivity"] for row in rows}
        assert sensitivity_by_id[f"tweet:tweet-{marker}"] == "shared"
        assert sensitivity_by_id[f"dm:dm-{marker}:dm-message-{marker}"] == "private"
        assert any(f"Twitter archive marker {marker}" in doc["content"] for doc in opened)
        assert any(f"Private Twitter/X DM marker {marker}" in doc["content"] for doc in opened)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM connector_backfill_jobs WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connector_sync_cursors WHERE account_key = $1", account)
            await conn.execute("DELETE FROM integration_connections WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connection_attempts WHERE source_session_id = $1", marker)
            await conn.execute(
                "DELETE FROM source_documents WHERE path LIKE $1",
                f"twitter_x://{account}/%",
            )


async def test_twitter_live_backfill_stores_posts_as_connector_source_items(db_pool, monkeypatch, tmp_path):
    import core.auth.store as auth_store
    from core.auth.store import save_auth
    from core.auth.twitter_x import TWITTER_X_DEFAULT_CREDENTIAL_REF
    from core.auth.utils import now_ms
    from services import twitter_x

    marker = get_test_identifier("twitter-live")
    account = f"x:{marker.replace('-', '')[:12]}"
    user_id = account.removeprefix("x:")
    monkeypatch.setattr(auth_store, "AUTH_DIR", tmp_path / "auth")
    save_auth(
        TWITTER_X_DEFAULT_CREDENTIAL_REF,
        {
            "type": "twitter_x_oauth2",
            "token": "twitter-access-token",
            "refresh_token": "twitter-refresh-token",
            "client_id": "twitter-client",
            "expires_ms": now_ms() + 3_600_000,
            "account_key": account,
            "user_id": user_id,
            "username": "hexis_test",
            "scopes": ["tweet.read", "users.read", "offline.access"],
        },
    )

    try:
        async with db_pool.acquire() as conn:
            await _connected_channel(
                conn,
                "twitter_x",
                marker,
                account,
                capabilities=["read", "search", "ingest"],
            )
            queued = _j(await conn.fetchval(
                """
                SELECT enqueue_connector_backfill_job(
                    'twitter_x',
                    $1,
                    'messages',
                    $2::jsonb,
                    '{"test": true}'::jsonb,
                    3
                )
                """,
                account,
                json.dumps({"stream": "timeline", "max_messages": 2, "page_size": 10}),
            ))
            claimed = _j(await conn.fetchval(
                "SELECT claim_connector_backfill_jobs_for('twitter_x', 1)"
            ))
            job = claimed[0]

        async def fake_twitter_request(credentials, method, path, *, params=None, json_body=None):
            assert credentials["token"] == "twitter-access-token"
            assert method == "GET"
            assert path == f"/users/{user_id}/tweets"
            assert params["max_results"] == 10
            return {
                "data": [
                    {
                        "id": f"tweet-{marker}",
                        "text": f"Twitter live marker {marker}",
                        "created_at": "2026-07-20T10:00:00.000Z",
                        "author_id": user_id,
                        "conversation_id": f"conv-{marker}",
                    }
                ],
                "meta": {},
                "_rate_limit": {"x-rate-limit-remaining": "14"},
            }

        monkeypatch.setattr(twitter_x, "twitter_x_request", fake_twitter_request)
        result = await channel_backfill.process_channel_backfill_job(db_pool, job)

        async with db_pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT provider_item_id, item_kind, source_document_id, sensitivity
                FROM connector_source_items
                WHERE account_key = $1
                ORDER BY provider_item_id
                """,
                account,
            )
            opened = _j(await conn.fetchval("SELECT open_source_document($1::uuid)", rows[0]["source_document_id"]))

        assert result["status"] == "completed"
        assert result["result"]["items_stored"] == 1
        assert result["result"]["rate_limit"]["x-rate-limit-remaining"] == "14"
        assert queued["estimate"]["provider_status"] == "api_backfill_available"
        assert rows[0]["provider_item_id"] == f"tweet:tweet-{marker}"
        assert rows[0]["item_kind"] == "post"
        assert rows[0]["sensitivity"] == "shared"
        assert f"Twitter live marker {marker}" in opened["content"]
        assert opened["source_attribution"]["connector_id"] == "twitter_x"
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM connector_backfill_jobs WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connector_sync_cursors WHERE account_key = $1", account)
            await conn.execute("DELETE FROM integration_connections WHERE account_key = $1", account)
            await conn.execute("DELETE FROM connection_attempts WHERE source_session_id = $1", marker)
            await conn.execute(
                "DELETE FROM source_documents WHERE path LIKE $1",
                f"twitter_x://{account}/%",
            )
