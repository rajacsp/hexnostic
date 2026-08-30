"""HMX Slice 7 portable consolidation and reconsolidation work."""

from __future__ import annotations

import json
import uuid

import pytest

from core.digest import content_hash_v1
from core.memory_exchange import (
    HmxAnalysisResult,
    build_envelope,
    dry_run_hmx,
    export_hmx,
    import_hmx,
    iter_hmx_jsonl,
    parse_hmx_jsonl,
    resolve_export_sections,
)

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _json(value):
    return json.loads(value) if isinstance(value, str) else value


async def _prepare(conn):
    await conn.execute("LOAD 'age'")
    await conn.execute('SET search_path = public, ag_catalog, "$user"')


async def _envelope(conn, intent: str = "port") -> dict:
    lineage = await conn.fetchval(
        "SELECT value #>> '{}' FROM config WHERE key='agent.lineage_id'"
    )
    return build_envelope(
        intent=intent,
        plan=resolve_export_sections(intent),
        instance_id="hmx_slice7_source",
        schema_version="0011_hmx_in_flight_work",
        embedding_model="source-model",
        embedding_dimension=768,
        lineage_id=str(lineage),
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
        "metadata": {},
        "provenance": {
            "acquisition_mode": "experienced",
            "origin_instance": "hmx_slice7_source",
            "origin_id": source_id,
            "import_chain": [],
            "modification_chain": [],
        },
    }


def _raw(envelope: dict, *, route_status: str = "merge_queued") -> dict:
    return {
        "ref": f"{envelope['export_id']}:{uuid.uuid4()}",
        "user_text": f"slice7 raw {uuid.uuid4().hex}",
        "assistant_text": "noted",
        "source_identity": f"slice7:{uuid.uuid4().hex}",
        "route_status": route_status,
    }


async def test_export_scopes_task_refs_and_omits_runtime_state(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            memory_id = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding) VALUES "
                "('semantic', $1, array_fill(0.0::float, "
                "ARRAY[embedding_dimension()])::vector) RETURNING id",
                f"slice7 export memory {uuid.uuid4().hex}",
            )
            unit_id = await conn.fetchval(
                "SELECT (recmem_ingest_turn($1, 'noted', NULL, $2)->>'unit_id')::uuid",
                f"slice7 export raw {uuid.uuid4().hex}",
                f"slice7-export:{uuid.uuid4().hex}",
            )
            task_id = await conn.fetchval(
                "INSERT INTO recmem_consolidation_tasks ("
                "task_type, trigger_unit_id, target_memory_id, source_unit_ids, "
                "status, started_at, attempts, result, task_payload) VALUES ("
                "'episode_merge', $1::uuid, $2::uuid, ARRAY[$1]::uuid[], 'in_progress', "
                "CURRENT_TIMESTAMP, 2, '{\"runtime\":true}'::jsonb, "
                "jsonb_build_object('target_memory_id', $2, "
                "'source_unit_ids', ARRAY[$1]::uuid[], 'similarity', 0.9)) "
                "RETURNING id",
                unit_id,
                memory_id,
            )
            recon_id = await conn.fetchval(
                "INSERT INTO reconsolidation_tasks ("
                "belief_id, old_content, new_content, transformation_type, "
                "status, processed_count, error_message, started_at) VALUES ("
                "$1, 'before', 'after', 'shift', 'failed', 4, "
                "'source failure', CURRENT_TIMESTAMP) RETURNING id",
                memory_id,
            )

            envelope = await export_hmx(conn, intent="port", include_raw_units=True)
            work = envelope["sections"]["in_flight_work"]
            consolidation = next(
                task
                for task in work["consolidation_tasks"]
                if task["ref"].endswith(str(task_id))
            )
            assert consolidation["input_refs"] == [f"{envelope['export_id']}:{unit_id}"]
            assert consolidation["trigger_ref"] == (
                f"{envelope['export_id']}:{unit_id}"
            )
            assert consolidation["output_refs"] == [
                f"{envelope['export_id']}:{memory_id}"
            ]
            assert consolidation["attempt_count"] == 2
            assert consolidation["properties"] == {"similarity": 0.9}
            for runtime_field in (
                "started_at",
                "completed_at",
                "next_attempt_at",
                "result",
            ):
                assert runtime_field not in consolidation

            recon = next(
                task
                for task in work["reconsolidation_tasks"]
                if task["ref"].endswith(str(recon_id))
            )
            assert recon["memory_refs"] == [f"{envelope['export_id']}:{memory_id}"]
            assert recon["properties"] == {
                "old_content": "before",
                "new_content": "after",
                "error": "source failure",
            }
            assert "processed_count" not in recon
            assert "started_at" not in recon

            restored = parse_hmx_jsonl(iter_hmx_jsonl(envelope))
            assert restored["sections"]["in_flight_work"] == work

            without_raw = await export_hmx(conn, intent="port")
            assert any(
                "--include-raw" in warning
                for warning in without_raw.get("export_warnings", [])
            )
        finally:
            await transaction.rollback()


async def test_in_progress_task_is_remapped_requeued_and_idempotent(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = await _envelope(conn)
            memory = _memory(envelope, f"slice7 target {uuid.uuid4().hex}")
            raw = _raw(envelope)
            task_ref = f"{envelope['export_id']}:{uuid.uuid4()}"
            envelope["sections"] = {
                "memories": [memory],
                "raw_units": [raw],
                "in_flight_work": {
                    "consolidation_tasks": [
                        {
                            "ref": task_ref,
                            "task_type": "episode_merge",
                            "status": "in_progress",
                            "input_refs": [raw["ref"]],
                            "trigger_ref": raw["ref"],
                            "output_refs": [memory["ref"]],
                            "attempt_count": 2,
                            "properties": {"similarity": 0.88},
                        }
                    ],
                    "reconsolidation_tasks": [],
                },
            }

            forecast = await dry_run_hmx(conn, envelope, strategy="additive")
            assert forecast.counts["in_flight_work"] == 1
            assert not any(
                warning.get("section") == "in_flight_work"
                and warning.get("code") == "unsupported_section"
                for warning in forecast.warnings
            )

            imported = await import_hmx(conn, envelope, strategy="additive")
            assert imported.inserted["in_flight_work"] == 1, imported
            task_id = imported.ref_map[task_ref]
            unit_id = imported.ref_map[raw["ref"]]
            memory_id = imported.ref_map[memory["ref"]]
            task = await conn.fetchrow(
                "SELECT status, started_at, completed_at, next_attempt_at, "
                "attempts, trigger_unit_id, target_memory_id, source_unit_ids, "
                "task_payload FROM recmem_consolidation_tasks WHERE id=$1::uuid",
                task_id,
            )
            assert task["status"] == "pending"
            assert task["started_at"] is None
            assert task["completed_at"] is None
            assert task["attempts"] == 2
            assert str(task["trigger_unit_id"]) == unit_id
            assert str(task["target_memory_id"]) == memory_id
            assert [str(value) for value in task["source_unit_ids"]] == [unit_id]
            assert _json(task["task_payload"])["hmx"]["source_status"] == (
                "in_progress"
            )
            assert (
                await conn.fetchval(
                    "SELECT route_status FROM subconscious_units WHERE id=$1::uuid",
                    unit_id,
                )
                == "merge_queued"
            )

            claimed = _json(
                await conn.fetchval("SELECT claim_recmem_consolidation_task()")
            )
            assert str(claimed["id"]) == task_id
            assert claimed["attempts"] == 3

            await conn.execute(
                "UPDATE recmem_consolidation_tasks SET status='pending', "
                "started_at=NULL WHERE id=$1::uuid",
                task_id,
            )
            repeated = await import_hmx(conn, envelope, strategy="additive")
            assert repeated.inserted["in_flight_work"] == 0
            assert repeated.ref_map[task_ref] == task_id
            assert (
                await conn.fetchval(
                    "SELECT count(*) FROM hmx_imported_work_refs WHERE source_ref=$1",
                    task_ref,
                )
                == 1
            )
        finally:
            await transaction.rollback()


async def test_missing_inputs_are_dropped_with_preflight_and_import_warnings(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = await _envelope(conn)
            missing_raw_ref = f"{envelope['export_id']}:{uuid.uuid4()}"
            task_ref = f"{envelope['export_id']}:{uuid.uuid4()}"
            envelope["sections"] = {
                "in_flight_work": {
                    "consolidation_tasks": [
                        {
                            "ref": task_ref,
                            "task_type": "episode_create",
                            "status": "pending",
                            "input_refs": [missing_raw_ref],
                            "output_refs": [],
                        }
                    ],
                    "reconsolidation_tasks": [],
                }
            }

            forecast = await dry_run_hmx(conn, envelope, strategy="additive")
            assert forecast.counts["in_flight_work"] == 0
            predicted = next(
                warning
                for warning in forecast.warnings
                if warning.get("code") == "dropped_in_flight_task"
            )
            assert predicted["missing_refs"] == [missing_raw_ref]

            imported = await import_hmx(conn, envelope, strategy="additive")
            assert imported.inserted["in_flight_work"] == 0
            dropped = next(
                warning
                for warning in imported.warnings
                if warning.get("code") == "dropped_in_flight_task"
            )
            assert missing_raw_ref in dropped["missing_refs"]
            assert task_ref not in imported.ref_map
        finally:
            await transaction.rollback()


async def test_failed_tasks_stay_diagnostic_until_explicit_retry(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = await _envelope(conn)
            memory = _memory(envelope, f"slice7 failed belief {uuid.uuid4().hex}")
            raw = _raw(envelope, route_status="create_queued")
            consolidation_ref = f"{envelope['export_id']}:{uuid.uuid4()}"
            recon_ref = f"{envelope['export_id']}:{uuid.uuid4()}"
            envelope["sections"] = {
                "memories": [memory],
                "raw_units": [raw],
                "in_flight_work": {
                    "consolidation_tasks": [
                        {
                            "ref": consolidation_ref,
                            "task_type": "episode_create",
                            "status": "failed",
                            "input_refs": [raw["ref"]],
                            "trigger_ref": raw["ref"],
                            "output_refs": [],
                            "attempt_count": 3,
                            "error": "source recmem failure",
                            "properties": {},
                        }
                    ],
                    "reconsolidation_tasks": [
                        {
                            "ref": recon_ref,
                            "status": "failed",
                            "memory_refs": [memory["ref"]],
                            "reason": "shift",
                            "properties": {
                                "old_content": "old belief",
                                "new_content": "new belief",
                                "error": "source recon failure",
                            },
                        }
                    ],
                },
            }

            forecast = await dry_run_hmx(conn, envelope, strategy="additive")
            assert any(
                warning.get("code") == "failed_in_flight_preserved"
                for warning in forecast.warnings
            )
            imported = await import_hmx(conn, envelope, strategy="additive")
            consolidation_id = imported.ref_map[consolidation_ref]
            recon_id = imported.ref_map[recon_ref]
            assert imported.inserted["in_flight_work"] == 2
            assert imported.work_summary["failed_preserved"] == 2
            assert imported.work_summary["requeued"] == 0
            assert (
                await conn.fetchval(
                    "SELECT status FROM recmem_consolidation_tasks WHERE id=$1::uuid",
                    consolidation_id,
                )
                == "failed"
            )
            assert (
                await conn.fetchval(
                    "SELECT error_message FROM reconsolidation_tasks WHERE id=$1::uuid",
                    recon_id,
                )
                == "source recon failure"
            )
            assert (
                await conn.fetchval("SELECT claim_recmem_consolidation_task()") is None
            )
            assert await conn.fetchval("SELECT claim_reconsolidation_task()") is None

            retry_forecast = await dry_run_hmx(
                conn,
                envelope,
                strategy="additive",
                retry_failed_work=True,
            )
            assert any(
                warning.get("code") == "failed_in_flight_retry_requested"
                for warning in retry_forecast.warnings
            )
            retried = await import_hmx(
                conn,
                envelope,
                strategy="additive",
                retry_failed_work=True,
            )
            assert retried.ref_map[consolidation_ref] == consolidation_id
            assert retried.ref_map[recon_ref] == recon_id
            assert retried.work_summary["retried"] == 2
            assert retried.work_summary["requeued"] == 2
            assert (
                await conn.fetchval(
                    "SELECT status FROM recmem_consolidation_tasks WHERE id=$1::uuid",
                    consolidation_id,
                )
                == "pending"
            )
            assert (
                await conn.fetchval(
                    "SELECT attempts FROM recmem_consolidation_tasks WHERE id=$1::uuid",
                    consolidation_id,
                )
                == 0
            )
            assert (
                await conn.fetchval(
                    "SELECT status FROM reconsolidation_tasks WHERE id=$1::uuid",
                    recon_id,
                )
                == "pending"
            )
            diagnostic = await conn.fetchrow(
                "SELECT source_error, retried_at FROM hmx_imported_work_refs "
                "WHERE source_ref=$1",
                recon_ref,
            )
            assert diagnostic["source_error"] == "source recon failure"
            assert diagnostic["retried_at"] is not None
        finally:
            await transaction.rollback()


async def test_analysis_in_flight_work_remains_isolated(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = await _envelope(conn, "analysis")
            raw_ref = f"{envelope['export_id']}:{uuid.uuid4()}"
            envelope["sections"] = {
                "in_flight_work": {
                    "consolidation_tasks": [
                        {
                            "ref": f"{envelope['export_id']}:{uuid.uuid4()}",
                            "task_type": "episode_create",
                            "status": "pending",
                            "input_refs": [raw_ref],
                            "output_refs": [],
                        }
                    ],
                    "reconsolidation_tasks": [],
                }
            }
            result = await import_hmx(conn, envelope, strategy="analysis_only")
            assert isinstance(result, HmxAnalysisResult)
            assert result.loaded["in_flight_work"] == 1
            assert not await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM hmx_imported_work_refs "
                "WHERE export_id=$1)",
                envelope["export_id"],
            )
        finally:
            await transaction.rollback()
