"""HMX Slice 4 deliberative review and analysis-only isolation."""

from __future__ import annotations

import json
import uuid

import pytest

from core.digest import content_hash_v1
from core.memory_exchange import (
    HmxAnalysisResult,
    HmxPolicyError,
    HmxStagingResult,
    accept_staged_import,
    build_envelope,
    demote_staged_to_analysis,
    export_hmx,
    import_hmx,
    modify_staged_import,
    pending_hmx_reviews,
    promote_analysis_to_staged,
    quote_staged_import,
    reject_staged_import,
    resolve_export_sections,
)

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _json(value):
    return json.loads(value) if isinstance(value, str) else value


def _envelope(intent: str = "telepathy") -> dict:
    return build_envelope(
        intent=intent,
        plan=resolve_export_sections(intent),
        instance_id="hmx_slice4_source",
        schema_version="0009_hmx_deliberative_analysis",
        embedding_model="embeddinggemma:300m",
        embedding_dimension=768,
        lineage_id=str(uuid.uuid4()),
        relationship_edge_types=["SUPPORTS"],
    )


def _memory(env: dict, content: str) -> dict:
    source_id = str(uuid.uuid4())
    return {
        "ref": f"{env['export_id']}:{source_id}",
        "type": "semantic",
        "status": "active",
        "content": content,
        "content_hash_v1": content_hash_v1(content),
        "importance": 0.7,
        "trust_level": 0.8,
        "metadata": {},
        "provenance": {
            "acquisition_mode": "experienced",
            "origin_instance": "hmx_slice4_source",
            "origin_id": source_id,
            "import_chain": [],
            "modification_chain": [],
        },
    }


class TestIsolatedLoading:
    async def test_deliberative_stages_without_active_mutation(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                env = _envelope()
                record = _memory(env, f"staged only {uuid.uuid4().hex}")
                env["sections"] = {"memories": [record]}
                before = await conn.fetchval("SELECT count(*) FROM memories")

                result = await import_hmx(conn, env, strategy="deliberative")

                assert isinstance(result, HmxStagingResult)
                assert result.staged == {"memories": 1}
                assert await conn.fetchval("SELECT count(*) FROM memories") == before
                staged = await conn.fetchrow(
                    "SELECT status, record FROM hmx_import_staging WHERE id=$1::uuid",
                    result.staging_ids[0],
                )
                assert staged["status"] == "pending"
                assert (
                    _json(staged["record"])["provenance"]["acquisition_mode"]
                    == "imported_staged"
                )
                pending = await pending_hmx_reviews(conn)
                assert pending["total"] >= 1
                assert any(
                    item["id"] == result.staging_ids[0] for item in pending["records"]
                )
            finally:
                await tr.rollback()

    async def test_analysis_only_is_physically_isolated_and_not_pending_review(
        self, db_pool
    ):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                env = _envelope("analysis")
                record = _memory(env, f"analysis only {uuid.uuid4().hex}")
                env["sections"] = {"memories": [record]}
                memory_count = await conn.fetchval("SELECT count(*) FROM memories")
                state_counts = await conn.fetchrow(
                    "SELECT (SELECT count(*) FROM memory_neighborhoods) neighborhoods, "
                    "(SELECT count(*) FROM drives) drives, "
                    "(SELECT count(*) FROM emotional_triggers) triggers"
                )
                pending_before = _json(
                    await conn.fetchval("SELECT hmx_pending_review_summary()")
                )["count"]

                result = await import_hmx(conn, env, strategy="analysis_only")

                assert isinstance(result, HmxAnalysisResult)
                assert result.loaded == {"memories": 1}
                assert (
                    await conn.fetchval("SELECT count(*) FROM memories") == memory_count
                )
                assert (
                    await conn.fetchrow(
                        "SELECT (SELECT count(*) FROM memory_neighborhoods) neighborhoods, "
                        "(SELECT count(*) FROM drives) drives, "
                        "(SELECT count(*) FROM emotional_triggers) triggers"
                    )
                    == state_counts
                )
                assert (
                    _json(await conn.fetchval("SELECT hmx_pending_review_summary()"))[
                        "count"
                    ]
                    == pending_before
                )
                stored = _json(
                    await conn.fetchval(
                        "SELECT record FROM hmx_analysis_records WHERE id=$1::uuid",
                        result.analysis_ids[0],
                    )
                )
                assert stored["provenance"]["acquisition_mode"] == "analysis_only"
                assert not await conn.fetchval(
                    "SELECT EXISTS (SELECT 1 FROM information_schema.columns "
                    "WHERE table_name='hmx_analysis_records' AND column_name='embedding')"
                )
            finally:
                await tr.rollback()

    async def test_promote_copies_and_demote_preserves_both_histories(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                env = _envelope("analysis")
                env["sections"] = {
                    "memories": [_memory(env, f"transition {uuid.uuid4().hex}")]
                }
                analysis = await import_hmx(conn, env, strategy="analysis_only")
                analysis_id = analysis.analysis_ids[0]

                staging_id = await promote_analysis_to_staged(
                    conn, analysis_id, rationale="worth deliberating"
                )
                assert (
                    await conn.fetchval(
                        "SELECT count(*) FROM hmx_analysis_records WHERE id=$1::uuid",
                        analysis_id,
                    )
                    == 1
                )
                promoted = _json(
                    await conn.fetchval(
                        "SELECT record FROM hmx_import_staging WHERE id=$1::uuid",
                        staging_id,
                    )
                )
                assert promoted["provenance"]["acquisition_mode"] == "imported_staged"

                demoted_id = await demote_staged_to_analysis(
                    conn, staging_id, rationale="retain for inspection only"
                )
                assert (
                    await conn.fetchval(
                        "SELECT status FROM hmx_import_staging WHERE id=$1::uuid",
                        staging_id,
                    )
                    == "demoted"
                )
                demoted = _json(
                    await conn.fetchval(
                        "SELECT record FROM hmx_analysis_records WHERE id=$1::uuid",
                        demoted_id,
                    )
                )
                assert demoted["provenance"]["acquisition_mode"] == "analysis_only"
            finally:
                await tr.rollback()

    async def test_narrative_is_staged_as_one_reviewable_bundle(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                env = _envelope()
                chapter_ref = f"{env['export_id']}:{uuid.uuid4()}"
                env["sections"] = {
                    "narrative": {
                        "life_chapters": [
                            {
                                "ref": chapter_ref,
                                "title": "A staged chapter",
                                "status": "active",
                            }
                        ],
                        "turning_points": [],
                        "narrative_threads": [],
                        "value_conflicts": [],
                    }
                }

                result = await import_hmx(conn, env, strategy="deliberative")

                assert result.staged == {"narrative": 1}
                stored = _json(
                    await conn.fetchval(
                        "SELECT record FROM hmx_import_staging WHERE id=$1::uuid",
                        result.staging_ids[0],
                    )
                )
                assert stored["life_chapters"][0]["ref"] == chapter_ref
                assert (
                    await conn.fetchval(
                        "SELECT status FROM hmx_import_staging WHERE id=$1::uuid",
                        result.staging_ids[0],
                    )
                    == "pending"
                )
            finally:
                await tr.rollback()


class TestReviewDecisions:
    async def _stage_one(self, conn, content: str):
        env = _envelope()
        env["sections"] = {"memories": [_memory(env, content)]}
        result = await import_hmx(conn, env, strategy="deliberative")
        return result.staging_ids[0]

    async def test_accept_marks_provenance_and_ref_map(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                content = f"accepted staged {uuid.uuid4().hex}"
                staging_id = await self._stage_one(conn, content)
                decision = await accept_staged_import(
                    conn, staging_id, rationale="useful"
                )
                assert decision.decision == "accepted"
                assert decision.local_ref
                row = await conn.fetchrow(
                    "SELECT status, metadata FROM memories WHERE id=$1::uuid",
                    decision.local_ref,
                )
                assert row["status"] == "active"
                provenance = _json(row["metadata"])["provenance"]
                assert provenance["acquisition_mode"] == "imported_and_accepted"
                assert len(provenance["import_chain"]) == 1
                assert (
                    await conn.fetchval(
                        "SELECT status FROM hmx_import_staging WHERE id=$1::uuid",
                        staging_id,
                    )
                    == "accepted"
                )
            finally:
                await tr.rollback()

    async def test_reviewed_port_record_leaves_staged_mode(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                env = _envelope("port")
                env["sections"] = {
                    "memories": [_memory(env, f"reviewed port {uuid.uuid4().hex}")]
                }
                staged = await import_hmx(conn, env, strategy="deliberative")
                decision = await accept_staged_import(conn, staged.staging_ids[0])
                metadata = _json(
                    await conn.fetchval(
                        "SELECT metadata FROM memories WHERE id=$1::uuid",
                        decision.local_ref,
                    )
                )
                assert (
                    metadata["provenance"]["acquisition_mode"]
                    == "imported_and_accepted"
                )
                assert len(metadata["provenance"]["import_chain"]) == 1
            finally:
                await tr.rollback()

    async def test_material_modify_then_accept_becomes_derived(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                staging_id = await self._stage_one(
                    conn, f"before edit {uuid.uuid4().hex}"
                )
                revised = f"after edit {uuid.uuid4().hex}"
                await modify_staged_import(
                    conn,
                    staging_id,
                    {"content": revised},
                    modification_kind="correction",
                    rationale="correct the imported claim",
                )
                decision = await accept_staged_import(conn, staging_id)
                row = await conn.fetchrow(
                    "SELECT content, metadata FROM memories WHERE id=$1::uuid",
                    decision.local_ref,
                )
                assert row["content"] == revised
                provenance = _json(row["metadata"])["provenance"]
                assert provenance["acquisition_mode"] == "derived_from_import"
                assert (
                    provenance["modification_chain"][-1]["modification_kind"]
                    == "correction"
                )
            finally:
                await tr.rollback()

    async def test_non_material_modify_preserves_mode_and_reexports_chain(
        self, db_pool
    ):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                original = f"before clarification {uuid.uuid4().hex}"
                staging_id = await self._stage_one(conn, original)
                revised = original.capitalize()
                await modify_staged_import(
                    conn,
                    staging_id,
                    {"content": revised},
                    modification_kind="clarification",
                    rationale="improve readability without changing meaning",
                )

                decision = await accept_staged_import(conn, staging_id)
                exported = await export_hmx(conn, intent="port")
                record = next(
                    item
                    for item in exported["sections"]["memories"]
                    if item["content"] == revised
                )
                provenance = record["provenance"]

                assert decision.decision == "accepted"
                assert provenance["acquisition_mode"] == "imported_and_accepted"
                assert provenance["origin_instance"] == "hmx_slice4_source"
                assert len(provenance["import_chain"]) == 1
                modification = provenance["modification_chain"][-1]
                assert modification["modification_kind"] == "clarification"
                assert modification["instance_id"]
                assert modification["previous_content_hash_v1"] == content_hash_v1(
                    original
                )
                assert modification["new_content_hash_v1"] == content_hash_v1(revised)
            finally:
                await tr.rollback()

    async def test_reject_and_quote_do_not_create_active_memory(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                rejected = await self._stage_one(conn, f"reject {uuid.uuid4().hex}")
                await reject_staged_import(conn, rejected, rationale="not reliable")
                assert (
                    await conn.fetchval(
                        "SELECT status FROM hmx_import_staging WHERE id=$1::uuid",
                        rejected,
                    )
                    == "rejected"
                )

                quoted = await self._stage_one(conn, f"quote {uuid.uuid4().hex}")
                decision = await quote_staged_import(
                    conn, quoted, rationale="foreign context"
                )
                row = await conn.fetchrow(
                    "SELECT status, metadata FROM memories WHERE id=$1::uuid",
                    decision.local_ref,
                )
                assert row["status"] == "archived"
                assert _json(row["metadata"])["hmx"]["quoted"] is True
            finally:
                await tr.rollback()

    async def test_relationship_waits_for_record_reference_mapping(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                env = _envelope()
                left = _memory(env, f"left {uuid.uuid4().hex}")
                right = _memory(env, f"right {uuid.uuid4().hex}")
                env["sections"] = {
                    "memories": [left, right],
                    "relationships": [
                        {
                            "source_ref": left["ref"],
                            "target_ref": right["ref"],
                            "edge_type": "SUPPORTS",
                            "properties": {
                                "source_type": "memory",
                                "target_type": "memory",
                            },
                        }
                    ],
                }
                staged = await import_hmx(conn, env, strategy="deliberative")
                rows = await conn.fetch(
                    "SELECT id, section FROM hmx_import_staging WHERE batch_id=$1::uuid",
                    staged.batch_id,
                )
                relationship_id = str(
                    next(row["id"] for row in rows if row["section"] == "relationships")
                )
                with pytest.raises(
                    HmxPolicyError, match="accept referenced records first"
                ):
                    await accept_staged_import(conn, relationship_id)
                for row in rows:
                    if row["section"] == "memories":
                        await accept_staged_import(conn, str(row["id"]))
                decision = await accept_staged_import(conn, relationship_id)
                assert decision.decision == "accepted"
            finally:
                await tr.rollback()

    async def test_active_target_blocks_protected_acceptance(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                env = _envelope()
                worldview = _memory(env, f"foreign value {uuid.uuid4().hex}")
                worldview.update(
                    type="worldview",
                    category="value",
                    confidence=0.8,
                    stability=0.8,
                    supporting_refs=[],
                    contesting_refs=[],
                )
                env["sections"] = {"worldview": [worldview]}
                staged = await import_hmx(conn, env, strategy="deliberative")
                with pytest.raises(HmxPolicyError, match="bootstrap_state_violation"):
                    await accept_staged_import(conn, staged.staging_ids[0])
                assert (
                    await conn.fetchval(
                        "SELECT status FROM hmx_import_staging WHERE id=$1::uuid",
                        staged.staging_ids[0],
                    )
                    == "pending"
                )
            finally:
                await tr.rollback()
