"""HMX Slice 6 accepted-memory embedding and raw-unit routing."""

from __future__ import annotations

import json
import uuid

import pytest

from core.digest import content_hash_v1
from core.memory_exchange import (
    HmxAnalysisResult,
    HmxStagingResult,
    accept_staged_import,
    build_envelope,
    dry_run_hmx,
    import_hmx,
    resolve_export_sections,
)
from services.hmx_reembedding import run_hmx_reembed_step
from services.recmem import run_recmem_embed_step, run_recmem_route_step

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _json(value):
    return json.loads(value) if isinstance(value, str) else value


def _envelope(intent: str = "telepathy") -> dict:
    return build_envelope(
        intent=intent,
        plan=resolve_export_sections(intent),
        instance_id="hmx_slice6_source",
        schema_version="0010_hmx_reembedding",
        embedding_model="source-model",
        embedding_dimension=768,
        lineage_id=str(uuid.uuid4()),
        relationship_edge_types=["MEMBER_OF"],
    )


def _memory(envelope: dict, content: str) -> dict:
    source_id = str(uuid.uuid4())
    return {
        "ref": f"{envelope['export_id']}:{source_id}",
        "type": "semantic",
        "status": "active",
        "content": content,
        "content_hash_v1": content_hash_v1(content),
        "importance": 0.7,
        "trust_level": 0.8,
        "metadata": {},
        "provenance": {
            "acquisition_mode": "experienced",
            "origin_instance": "hmx_slice6_source",
            "origin_id": source_id,
            "import_chain": [],
            "modification_chain": [],
        },
    }


async def _stub_get_embedding(conn, axis: int = 2, *, fail: bool = False):
    if fail:
        await conn.execute("""
            CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
            RETURNS vector[] AS $$
            BEGIN
                RAISE EXCEPTION 'slice6 embedding unavailable';
            END;
            $$ LANGUAGE plpgsql;
            """)
        return
    await conn.execute("""
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(
                array_agg((
                    array_fill(0.0::float, ARRAY[$axis$::int - 1]) ||
                    ARRAY[1.0::float] ||
                    array_fill(0.0::float, ARRAY[embedding_dimension() - $axis$::int])
                )::vector),
                ARRAY[]::vector[]
            )
            FROM unnest(text_contents)
        $$ LANGUAGE sql;
        """.replace("$axis$", str(axis)))


async def _prepare(conn):
    await conn.execute("LOAD 'age'")
    # public FIRST (#77): the schema guard rejects functions created into
    # ag_catalog when a public twin exists — this stub used to land there.
    await conn.execute('SET search_path = public, ag_catalog, "$user"')


async def _make_target_bootstrap_only(conn):
    await conn.execute(
        "UPDATE memories SET metadata = jsonb_set(metadata, "
        "'{provenance,acquisition_mode}', '\"bootstrap\"'::jsonb, true) "
        "WHERE type IN ('worldview', 'goal')"
    )
    await conn.execute("DELETE FROM emotional_triggers")
    await conn.execute("UPDATE drives SET current_level=baseline, last_satisfied=NULL")


async def test_accepted_import_is_embedded_and_refreshes_derivatives(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _stub_get_embedding(conn)
            envelope = _envelope()
            record = _memory(envelope, f"slice6 accepted {uuid.uuid4().hex}")
            envelope["sections"] = {"memories": [record]}
            staged = await import_hmx(conn, envelope, strategy="deliberative")
            assert isinstance(staged, HmxStagingResult)
            accepted = await accept_staged_import(
                conn, staged.staging_ids[0], rationale="admit after review"
            )
            memory_id = accepted.local_ref
            assert memory_id

            before = await conn.fetchrow(
                "SELECT metadata, embedding = "
                "array_fill(0.0::float, ARRAY[embedding_dimension()])::vector AS zero "
                "FROM memories WHERE id=$1::uuid",
                memory_id,
            )
            assert _json(before["metadata"])["embedding_status"] == "pending_import"
            assert before["zero"]

            cluster_id = await conn.fetchval(
                "INSERT INTO clusters (cluster_type, name) "
                "VALUES ('theme', $1) RETURNING id",
                f"slice6 cluster {uuid.uuid4().hex}",
            )
            assert await conn.fetchval("SELECT sync_cluster_node($1)", cluster_id)
            assert await conn.fetchval(
                "SELECT link_memory_to_cluster_graph($1::uuid, $2::uuid, 1.0)",
                memory_id,
                cluster_id,
            )

            result = await run_hmx_reembed_step(conn)
            assert result["claimed"] == 1
            assert result["embedded"] == 1, result
            assert result["failed"] == 0
            assert result["derivatives"] == {
                "neighborhoods_recomputed": 1,
                "clusters_recomputed": 1,
            }

            after = await conn.fetchrow(
                "SELECT metadata, embedding <> "
                "array_fill(0.0::float, ARRAY[embedding_dimension()])::vector AS nonzero "
                "FROM memories WHERE id=$1::uuid",
                memory_id,
            )
            assert after["nonzero"]
            assert _json(after["metadata"])["embedding_status"] == "embedded"
            assert not await conn.fetchval(
                "SELECT is_stale FROM memory_neighborhoods WHERE memory_id=$1::uuid",
                memory_id,
            )
            assert await conn.fetchval(
                "SELECT centroid_embedding IS NOT NULL FROM clusters WHERE id=$1",
                cluster_id,
            )
            assert (await run_hmx_reembed_step(conn))["skipped"]
        finally:
            await transaction.rollback()


async def test_failed_embedding_retries_then_stops_with_diagnostics(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _stub_get_embedding(conn, fail=True)
            await conn.execute(
                "SELECT set_config('memory.hmx_reembed_max_attempts', '2'::jsonb)"
            )
            envelope = _envelope()
            record = _memory(envelope, f"slice6 retry {uuid.uuid4().hex}")
            envelope["sections"] = {"memories": [record]}
            imported = await import_hmx(conn, envelope, strategy="additive")
            memory_id = imported.ref_map[record["ref"]]

            first = await run_hmx_reembed_step(conn)
            assert first["failed"] == 1
            assert "slice6 embedding unavailable" in first["error"]
            assert (
                await conn.fetchval(
                    "SELECT metadata->>'embedding_status' FROM memories WHERE id=$1::uuid",
                    memory_id,
                )
                == "pending_import"
            )

            second = await run_hmx_reembed_step(conn)
            assert second["failed"] == 1
            metadata = _json(
                await conn.fetchval(
                    "SELECT metadata FROM memories WHERE id=$1::uuid", memory_id
                )
            )
            assert metadata["embedding_status"] == "failed_import"
            assert metadata["embedding_attempts"] == 2
            assert (
                "slice6 embedding unavailable" in metadata["embedding_error"]["message"]
            )
            assert (await run_hmx_reembed_step(conn))["skipped"]
        finally:
            await transaction.rollback()


async def test_staged_analysis_and_ordinary_memories_never_enter_hmx_queue(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            staged_envelope = _envelope()
            staged_envelope["sections"] = {
                "memories": [
                    _memory(staged_envelope, f"slice6 staged {uuid.uuid4().hex}")
                ]
            }
            staged = await import_hmx(conn, staged_envelope, strategy="deliberative")
            assert isinstance(staged, HmxStagingResult)

            analysis_envelope = _envelope("analysis")
            analysis_envelope["sections"] = {
                "memories": [
                    _memory(analysis_envelope, f"slice6 analysis {uuid.uuid4().hex}")
                ]
            }
            analysis = await import_hmx(
                conn, analysis_envelope, strategy="analysis_only"
            )
            assert isinstance(analysis, HmxAnalysisResult)

            ordinary_id = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding, metadata) VALUES "
                "('semantic', $1, array_fill(0.0::float, "
                "ARRAY[embedding_dimension()])::vector, "
                '\'{"embedding_status":"pending_import"}\'::jsonb) RETURNING id',
                f"ordinary {uuid.uuid4().hex}",
            )
            queued = _json(
                await conn.fetchval(
                    "SELECT hmx_queue_reembed(ARRAY[$1]::uuid[])", ordinary_id
                )
            )
            assert queued["queued"] == 0
            assert (await run_hmx_reembed_step(conn))["skipped"]
        finally:
            await transaction.rollback()


async def test_port_raw_units_enter_recmem_idempotently_and_keep_links(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _stub_get_embedding(conn, axis=3)
            await _make_target_bootstrap_only(conn)
            envelope = _envelope("port")
            record = _memory(envelope, f"slice6 raw source {uuid.uuid4().hex}")
            raw_ref = f"{envelope['export_id']}:{uuid.uuid4()}"
            envelope["sections"] = {
                "memories": [record],
                "raw_units": [
                    {
                        "ref": raw_ref,
                        "user_text": "remember the slice6 raw detail",
                        "assistant_text": "noted",
                        "importance": 0.8,
                        "source_identity": "chat:source:1",
                        "idempotency_key": "source-idempotency",
                        "route_status": "episode_created",
                        "derived_memory_refs": [record["ref"]],
                    }
                ],
            }

            forecast = await dry_run_hmx(conn, envelope, strategy="additive")
            assert forecast.can_import
            assert forecast.counts["raw_units"] == 1
            assert forecast.estimated_embedding_items == 2
            assert not any(
                warning.get("section") == "raw_units" for warning in forecast.warnings
            )

            imported = await import_hmx(conn, envelope, strategy="additive")
            assert imported.inserted["raw_units"] == 1
            unit_id = imported.ref_map[raw_ref]
            memory_id = imported.ref_map[record["ref"]]
            unit = await conn.fetchrow(
                "SELECT source_identity, idempotency_key, embedding_status, "
                "route_status, metadata FROM subconscious_units WHERE id=$1::uuid",
                unit_id,
            )
            expected_source = f"import:{envelope['export_id']}:chat:source:1"
            assert unit["source_identity"] == expected_source
            assert unit["idempotency_key"] == f"src:{expected_source}"
            assert unit["embedding_status"] == "pending"
            assert unit["route_status"] == "unrouted"
            assert _json(unit["metadata"])["hmx"]["source_idempotency_key"] == (
                "source-idempotency"
            )
            assert await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM memory_source_units "
                "WHERE memory_id=$1::uuid AND subconscious_unit_id=$2::uuid)",
                memory_id,
                unit_id,
            )

            await conn.execute(
                "SELECT set_config('memory.recmem_theta_count', '3'::jsonb)"
            )
            assert (await run_recmem_embed_step(conn))["embedded"] == 1
            route = await run_recmem_route_step(conn)
            assert route["outcomes"]["raw_only"] == 1

            repeated = await import_hmx(conn, envelope, strategy="additive")
            assert repeated.inserted["raw_units"] == 0
            assert repeated.ref_map[raw_ref] == unit_id
            assert (
                await conn.fetchval(
                    "SELECT count(*) FROM subconscious_units WHERE source_identity=$1",
                    expected_source,
                )
                == 1
            )
        finally:
            await transaction.rollback()


async def test_telepathy_raw_units_remain_outside_active_recmem(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = _envelope("telepathy")
            raw_ref = f"{envelope['export_id']}:{uuid.uuid4()}"
            envelope["sections"] = {
                "raw_units": [
                    {
                        "ref": raw_ref,
                        "user_text": "foreign raw detail",
                        "assistant_text": "foreign response",
                    }
                ]
            }
            forecast = await dry_run_hmx(conn, envelope, strategy="additive")
            assert forecast.counts["raw_units"] == 0
            assert any(
                warning.get("section") == "raw_units" for warning in forecast.warnings
            )

            result = await import_hmx(conn, envelope, strategy="additive")
            assert "raw_units" not in result.inserted
            assert raw_ref not in result.ref_map
            assert not await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM subconscious_units "
                "WHERE source_identity LIKE $1)",
                f"import:{envelope['export_id']}:%",
            )
        finally:
            await transaction.rollback()
