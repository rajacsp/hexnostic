"""HMX Slice 10-11 authoritative replacement and reversion journeys."""

from __future__ import annotations

import base64
import copy
import json
import uuid

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from core.digest import content_hash_v1, protected_section_digest_v1
from core.memory_exchange import dry_run_hmx, export_hmx, import_hmx
from core.protected_replacement import (
    OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
    ProtectedReplacementError,
    acknowledge_protected_replacement,
    inspect_protected_replacement,
    open_protected_reversion_windows,
    operator_override_signing_payload,
    revert_protected_replacement,
)
from core.trust_anchors import Ed25519TrustAnchors, TrustVerification

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


class VerifiedTrustAnchors:
    def verify_operator_signature(self, **kwargs):
        return TrustVerification.accepted(anchor_id="slice-10-operator")

    def verify_source_identity(self, **kwargs):
        return TrustVerification.accepted(anchor_id="slice-10-source")

    def verify_lineage(self, **kwargs):
        return TrustVerification.accepted(anchor_id="slice-10-lineage")


async def _prepare(conn) -> None:
    await conn.execute("LOAD 'age'")
    await conn.execute('SET search_path = public, ag_catalog, "$user"')
    token = uuid.uuid4().hex
    await conn.execute(
        "INSERT INTO memories "
        "(type, content, embedding, importance, trust_level, status, metadata) "
        "VALUES "
        "('worldview', $1, array_fill(0.1, ARRAY[embedding_dimension()])::vector, "
        "0.9, 0.95, 'active', $2::jsonb), "
        "('goal', $3, array_fill(0.1, ARRAY[embedding_dimension()])::vector, "
        "0.8, 0.8, 'active', $4::jsonb)",
        f"Authoritative worldview {token}",
        json.dumps(
            {
                "category": "value",
                "confidence": 0.95,
                "stability": 0.9,
                "provenance": {"acquisition_mode": "experienced"},
            }
        ),
        f"Authoritative goal {token}",
        json.dumps(
            {
                "title": f"Authoritative goal {token}",
                "description": f"Goal description {token}",
                "priority": "queued",
                "source": "curiosity",
                "due_at": None,
                "progress": [],
                "blocked_by": [],
                "provenance": {"acquisition_mode": "experienced"},
            }
        ),
    )
    await conn.execute(
        "INSERT INTO emotional_triggers "
        "(trigger_pattern, trigger_embedding, valence_delta, arousal_delta, "
        "dominance_delta, typical_emotion, confidence, origin, metadata) "
        "VALUES ($1, array_fill(0.0, ARRAY[embedding_dimension()])::vector, "
        "0.2, 0.1, 0.1, 'curiosity', 0.9, 'learned', $2::jsonb)",
        f"authoritative trigger {token}",
        json.dumps({"provenance": {"acquisition_mode": "experienced"}}),
    )
    if not await conn.fetchval("SELECT EXISTS (SELECT 1 FROM drives)"):
        await conn.execute(
            "INSERT INTO drives (name, description, current_level, baseline) "
            "VALUES ('curiosity', 'Learn', 0.5, 0.5)"
        )
    await conn.execute(
        "SELECT set_config('agent.init_profile', $1::jsonb)",
        json.dumps({"agent": {"description": f"Identity {token}"}}),
    )
    await conn.execute("SELECT ensure_self_node()")
    await conn.execute(
        "SELECT upsert_self_concept_edge('identity', $1, 0.85, NULL)",
        f"concept {token}",
    )
    await conn.execute("SELECT ensure_current_life_chapter($1)", f"Chapter {token}")


def _mutate_section(envelope: dict, section: str) -> None:
    token = uuid.uuid4().hex
    value = envelope["sections"][section]
    if section == "worldview":
        record = value[0]
        record["content"] = f"Replaced worldview {token}"
        record["content_hash_v1"] = content_hash_v1(record["content"])
    elif section == "goals":
        record = value[0]
        record["title"] = f"Replaced goal {token}"
        record["description"] = f"Replaced goal description {token}"
        record["metadata"]["title"] = record["title"]
        record["metadata"]["description"] = record["description"]
    elif section == "drives":
        record = value[0]
        record["current_level"] = min(
            0.99, max(0.01, float(record.get("current_level", 0.5)) + 0.137)
        )
    elif section == "emotional_triggers":
        record = value[0]
        record["trigger_pattern"] = f"replaced trigger {token}"
        record["content_hash_v1"] = content_hash_v1(record["trigger_pattern"])
    elif section == "identity":
        record = value[0]
        record["content"] = f"Replaced identity {token}"
        record["profile"]["description"] = record["content"]
    else:
        for group in (
            "life_chapters",
            "turning_points",
            "narrative_threads",
            "value_conflicts",
        ):
            if value.get(group):
                record = value[group][0]
                field = {
                    "life_chapters": "title",
                    "turning_points": "title",
                    "narrative_threads": "name",
                    "value_conflicts": "summary",
                }[group]
                record[field] = f"Replaced narrative {token}"
                if group == "life_chapters":
                    record["name"] = record[field]
                break
        else:  # pragma: no cover - _prepare always creates a chapter
            raise AssertionError("narrative export was unexpectedly empty")
    envelope["section_digests"][section] = protected_section_digest_v1(
        section, envelope["sections"][section]
    )


async def _execute_changed_section(conn, section: str, rationale: str):
    envelope = await export_hmx(conn, intent="port")
    before = copy.deepcopy(envelope)
    _mutate_section(envelope, section)
    requested = await import_hmx(
        conn,
        envelope,
        strategy="authoritative",
        replace_sections=[section],
        replacement_rationale=rationale,
        verifier=VerifiedTrustAnchors(),
    )
    replacement_id = requested.protected_operations[0]["replacement_id"]
    executed = await acknowledge_protected_replacement(
        conn,
        replacement_id,
        decision="accept",
        executor="agent_tool",
    )
    return envelope, before, executed


@pytest.mark.parametrize(
    "section",
    [
        "identity",
        "worldview",
        "goals",
        "drives",
        "emotional_triggers",
        "narrative",
    ],
)
async def test_authoritative_acceptance_and_reversion_verify_each_section(
    db_pool, section
):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            envelope = await export_hmx(conn, intent="port")
            _mutate_section(envelope, section)
            imported_digest = envelope["section_digests"][section]
            before_export = await export_hmx(conn, intent="port")
            before_digests = before_export["section_digests"]
            before_digest = before_digests[section]
            assert imported_digest != before_digest

            requested = await import_hmx(
                conn,
                envelope,
                strategy="authoritative",
                replace_sections=[section],
                replacement_rationale=f"Exercise authoritative {section}",
                verifier=VerifiedTrustAnchors(),
            )
            operation = requested.protected_operations[0]
            assert operation["disposition"] == "pending_acknowledgement"
            assert operation["replacement_id"]
            assert (await export_hmx(conn, intent="port"))["section_digests"][
                section
            ] == before_digest
            inspected = await inspect_protected_replacement(
                conn, operation["replacement_id"]
            )
            assert inspected["imported_digest_v1"] == imported_digest
            assert inspected["current_local_digest_v1"] == before_digest
            assert inspected["local_state_changed_since_request"] is False
            assert inspected["imported_section"] == envelope["sections"][section]

            executed = await acknowledge_protected_replacement(
                conn,
                operation["replacement_id"],
                decision="accept",
                executor="agent_tool",
            )
            assert executed["status"] == "executed"
            assert executed["snapshot_id"]
            assert executed["audit_id"]
            executed_inspection = await inspect_protected_replacement(
                conn, operation["replacement_id"]
            )
            assert executed_inspection["current_matches_executed_state"] is True
            assert executed_inspection["reversion_state_eligible"] is True
            assert executed_inspection["reversion_window"]["window_open"] is True
            assert executed_inspection["execution_audit_id"] == executed["audit_id"]
            after = await export_hmx(conn, intent="port")
            assert after["section_digests"][section] == imported_digest
            for untouched_section, untouched_digest in before_digests.items():
                if untouched_section != section:
                    assert (
                        after["section_digests"][untouched_section] == untouched_digest
                    )
            if section == "narrative":
                current_chapter = next(
                    record
                    for record in envelope["sections"]["narrative"]["life_chapters"]
                    if record.get("key") == "current"
                )
                assert (
                    await conn.fetchval(
                        "SELECT get_narrative_context()->'current_chapter'->>'name'"
                    )
                    == current_chapter["name"]
                )
            if section == "identity":
                assert await conn.fetchval(
                    "SELECT EXISTS (SELECT 1 FROM "
                    "jsonb_array_elements(get_self_model_context(200)) facet "
                    "WHERE facet->>'kind' = 'life_chapter_current')"
                )

            audit = await conn.fetchval(
                "SELECT record FROM protected_replacement_audit WHERE audit_id=$1",
                executed["audit_id"],
            )
            audit = json.loads(audit) if isinstance(audit, str) else audit
            assert audit["previous_state_digest_v1"] == before_digest
            assert audit["new_state_digest_v1"] == imported_digest
            assert audit["previous_state_snapshot_ref"] == executed["snapshot_id"]
            assert audit["agent_acknowledgement"] == "accepted"

            windows = await open_protected_reversion_windows(conn)
            assert any(
                record["audit_id"] == executed["audit_id"]
                for record in windows["records"]
            )
            reverted = await revert_protected_replacement(
                conn,
                executed["audit_id"],
                rationale=f"Exercise bounded {section} reversion",
            )
            assert reverted["status"] == "reverted"
            restored = await export_hmx(conn, intent="port")
            assert restored["section_digests"] == before_digests
            if section == "narrative":
                previous_chapter = next(
                    record
                    for record in before_export["sections"]["narrative"][
                        "life_chapters"
                    ]
                    if record.get("key") == "current"
                )
                assert (
                    await conn.fetchval(
                        "SELECT get_narrative_context()->'current_chapter'->>'name'"
                    )
                    == previous_chapter["name"]
                )
            if section == "identity":
                assert await conn.fetchval(
                    "SELECT EXISTS (SELECT 1 FROM "
                    "jsonb_array_elements(get_self_model_context(200)) facet "
                    "WHERE facet->>'kind' = 'life_chapter_current')"
                )

            reversion_audit = await conn.fetchval(
                "SELECT record FROM protected_replacement_audit WHERE audit_id=$1",
                reverted["audit_id"],
            )
            reversion_audit = (
                json.loads(reversion_audit)
                if isinstance(reversion_audit, str)
                else reversion_audit
            )
            assert reversion_audit["reverts_audit_id"] == executed["audit_id"]
            assert reversion_audit["restored_state_digest_v1"] == before_digest
            assert reversion_audit["post_reversion_digest_v1"] == before_digest
            snapshot = await conn.fetchrow(
                "SELECT snapshot_state, consumed_at, consumed_by_audit_id, "
                "purged_at, purge_reason FROM protected_replacement_snapshots "
                "WHERE snapshot_id=$1::uuid",
                executed["snapshot_id"],
            )
            assert snapshot["snapshot_state"] is None
            assert snapshot["consumed_at"] is not None
            assert snapshot["consumed_by_audit_id"] == reverted["audit_id"]
            assert snapshot["purged_at"] is not None
            assert snapshot["purge_reason"] == "consumed_by_reversion"
            reverted_inspection = await inspect_protected_replacement(
                conn, operation["replacement_id"]
            )
            assert reverted_inspection["status"] == "reverted"
            assert reverted_inspection["reversion_state_eligible"] is False
            assert reverted_inspection["reversion_window"]["window_open"] is False
            assert reverted_inspection["reversion_audit_id"] == reverted["audit_id"]
            assert not any(
                record["audit_id"] == executed["audit_id"]
                for record in (await open_protected_reversion_windows(conn))["records"]
            )

            replay = await revert_protected_replacement(
                conn,
                executed["audit_id"],
                rationale="Idempotent retry after a lost tool response",
            )
            assert replay["status"] == "already_reverted"
            assert replay["audit_id"] == reverted["audit_id"]
            assert replay["reused"] is True
        finally:
            await transaction.rollback()


async def test_reversion_refuses_to_overwrite_state_changed_after_replacement(db_pool):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            envelope, _, executed = await _execute_changed_section(
                conn, "drives", "Exercise post-replacement drift protection"
            )
            drive_name = envelope["sections"]["drives"][0]["name"]
            await conn.execute(
                "UPDATE drives SET current_level=LEAST(0.99, current_level+0.023) "
                "WHERE name=$1",
                drive_name,
            )
            changed_digest = (await export_hmx(conn, intent="port"))["section_digests"][
                "drives"
            ]

            with pytest.raises(
                Exception, match="protected_state_changed_since_replacement"
            ):
                await revert_protected_replacement(
                    conn,
                    executed["audit_id"],
                    rationale="Do not overwrite later drive reflection",
                )

            assert (await export_hmx(conn, intent="port"))["section_digests"][
                "drives"
            ] == changed_digest
            row = await conn.fetchrow(
                "SELECT p.status, p.reversion_audit_id, s.snapshot_state, "
                "s.consumed_at FROM hmx_pending_replacements p "
                "JOIN protected_replacement_snapshots s ON s.snapshot_id=p.snapshot_id "
                "WHERE p.execution_audit_id=$1",
                executed["audit_id"],
            )
            assert row["status"] == "executed"
            assert row["reversion_audit_id"] is None
            assert row["snapshot_state"] is not None
            assert row["consumed_at"] is None
        finally:
            await transaction.rollback()


async def test_reversion_window_expiry_purges_payload_and_blocks_restore(db_pool):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            envelope, _, executed = await _execute_changed_section(
                conn, "drives", "Exercise bounded reversion expiry"
            )
            await conn.execute(
                "UPDATE heartbeat_state SET heartbeat_count=heartbeat_count+7 WHERE id=1"
            )

            with pytest.raises(Exception, match="reversion_window_closed"):
                await revert_protected_replacement(
                    conn,
                    executed["audit_id"],
                    rationale="This request arrived after the bounded window",
                )

            assert (await export_hmx(conn, intent="port"))["section_digests"][
                "drives"
            ] == envelope["section_digests"]["drives"]
            snapshot = await conn.fetchrow(
                "SELECT snapshot_state, consumed_at, purged_at, purge_reason "
                "FROM protected_replacement_snapshots WHERE snapshot_id=$1::uuid",
                executed["snapshot_id"],
            )
            assert snapshot["snapshot_state"] is None
            assert snapshot["consumed_at"] is None
            assert snapshot["purged_at"] is not None
            assert snapshot["purge_reason"] == "heartbeat_window_expired"
        finally:
            await transaction.rollback()


async def test_failed_reversion_rolls_back_audit_snapshot_and_state(db_pool):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            envelope, _, executed = await _execute_changed_section(
                conn, "drives", "Force atomic reversion rollback"
            )
            audit_count = await conn.fetchval(
                "SELECT count(*) FROM protected_replacement_audit"
            )
            await conn.execute(
                "CREATE FUNCTION pg_temp.reject_reversion_drive_delete() "
                "RETURNS trigger AS $$ BEGIN RAISE EXCEPTION "
                "'forced reversion delete failure'; END; $$ LANGUAGE plpgsql"
            )
            await conn.execute(
                "CREATE TRIGGER reject_reversion_drive_delete BEFORE DELETE ON drives "
                "FOR EACH STATEMENT EXECUTE FUNCTION "
                "pg_temp.reject_reversion_drive_delete()"
            )

            with pytest.raises(Exception, match="forced reversion delete failure"):
                await revert_protected_replacement(
                    conn,
                    executed["audit_id"],
                    rationale="Exercise all-or-nothing restore",
                )

            assert (
                await conn.fetchval("SELECT count(*) FROM protected_replacement_audit")
                == audit_count
            )
            assert (await export_hmx(conn, intent="port"))["section_digests"][
                "drives"
            ] == envelope["section_digests"]["drives"]
            row = await conn.fetchrow(
                "SELECT p.status, p.reversion_audit_id, s.snapshot_state, "
                "s.consumed_at FROM hmx_pending_replacements p "
                "JOIN protected_replacement_snapshots s ON s.snapshot_id=p.snapshot_id "
                "WHERE p.execution_audit_id=$1",
                executed["audit_id"],
            )
            assert row["status"] == "executed"
            assert row["reversion_audit_id"] is None
            assert row["snapshot_state"] is not None
            assert row["consumed_at"] is None
        finally:
            await transaction.rollback()


async def test_reversion_restores_worldview_evidence_reference(db_pool):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            evidence_id = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding) VALUES "
                "('semantic', $1, array_fill(0.1, "
                "ARRAY[embedding_dimension()])::vector) RETURNING id",
                f"Reversion evidence {uuid.uuid4().hex}",
            )
            worldview = await conn.fetchrow(
                "SELECT id, content FROM memories WHERE type='worldview' "
                "ORDER BY created_at DESC, id DESC LIMIT 1"
            )
            await conn.execute(
                "SELECT create_memory_relationship($1, $2, 'SUPPORTS', '{}'::jsonb)",
                evidence_id,
                worldview["id"],
            )
            assert await conn.fetchval(
                "SELECT EXISTS (SELECT 1 FROM memory_edges WHERE "
                "src_id=$1::text AND rel_type='SUPPORTS' AND dst_id=$2::text)",
                str(evidence_id),
                str(worldview["id"]),
            )

            _, _, executed = await _execute_changed_section(
                conn, "worldview", "Preserve evidence topology across reversion"
            )
            await revert_protected_replacement(
                conn,
                executed["audit_id"],
                rationale="Restore worldview and its supporting evidence",
            )

            restored_worldview_id = await conn.fetchval(
                "SELECT id FROM memories WHERE type='worldview' AND content=$1",
                worldview["content"],
            )
            assert restored_worldview_id is not None
            assert await conn.fetchval(
                "SELECT EXISTS (SELECT 1 FROM memory_edges WHERE "
                "src_type='memory' AND src_id=$1::text AND rel_type='SUPPORTS' "
                "AND dst_type='memory' AND dst_id=$2::text)",
                str(evidence_id),
                str(restored_worldview_id),
            )
        finally:
            await transaction.rollback()


async def test_failed_authoritative_write_rolls_back_acceptance_audit_and_snapshot(
    db_pool,
):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            envelope = await export_hmx(conn, intent="port")
            _mutate_section(envelope, "drives")
            before = (await export_hmx(conn, intent="port"))["section_digests"][
                "drives"
            ]
            requested = await import_hmx(
                conn,
                envelope,
                strategy="authoritative",
                replace_sections=["drives"],
                replacement_rationale="Force atomic execution rollback",
                verifier=VerifiedTrustAnchors(),
            )
            replacement_id = requested.protected_operations[0]["replacement_id"]
            audit_count = await conn.fetchval(
                "SELECT count(*) FROM protected_replacement_audit"
            )
            snapshot_count = await conn.fetchval(
                "SELECT count(*) FROM protected_replacement_snapshots"
            )
            await conn.execute(
                "CREATE FUNCTION pg_temp.reject_drive_delete() RETURNS trigger AS $$ "
                "BEGIN RAISE EXCEPTION 'forced drive delete failure'; END; $$ LANGUAGE plpgsql"
            )
            await conn.execute(
                "CREATE TRIGGER reject_drive_delete BEFORE DELETE ON drives "
                "FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.reject_drive_delete()"
            )

            with pytest.raises(Exception, match="forced drive delete failure"):
                await acknowledge_protected_replacement(
                    conn,
                    replacement_id,
                    decision="accept",
                    executor="agent_tool",
                )

            assert (
                await conn.fetchval(
                    "SELECT status FROM hmx_pending_replacements "
                    "WHERE replacement_id=$1::uuid",
                    replacement_id,
                )
                == "pending"
            )
            assert (
                await conn.fetchval("SELECT count(*) FROM protected_replacement_audit")
                == audit_count
            )
            assert (
                await conn.fetchval(
                    "SELECT count(*) FROM protected_replacement_snapshots"
                )
                == snapshot_count
            )
            assert (await export_hmx(conn, intent="port"))["section_digests"][
                "drives"
            ] == before
        finally:
            await transaction.rollback()


async def test_acceptance_refuses_to_overwrite_state_that_changed_while_pending(
    db_pool,
):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            envelope = await export_hmx(conn, intent="port")
            _mutate_section(envelope, "drives")
            requested = await import_hmx(
                conn,
                envelope,
                strategy="authoritative",
                replace_sections=["drives"],
                replacement_rationale="Detect local change before acceptance",
                verifier=VerifiedTrustAnchors(),
            )
            replacement_id = requested.protected_operations[0]["replacement_id"]
            drive_name = envelope["sections"]["drives"][0]["name"]
            await conn.execute(
                "UPDATE drives SET current_level=GREATEST(0.01, current_level-0.071) "
                "WHERE name=$1",
                drive_name,
            )
            inspected = await inspect_protected_replacement(conn, replacement_id)
            assert inspected["local_state_changed_since_request"] is True

            with pytest.raises(
                Exception, match="protected_state_changed_while_pending"
            ):
                await acknowledge_protected_replacement(
                    conn,
                    replacement_id,
                    decision="accept",
                    executor="agent_tool",
                )
            assert (
                await conn.fetchval(
                    "SELECT status FROM hmx_pending_replacements "
                    "WHERE replacement_id=$1::uuid",
                    replacement_id,
                )
                == "pending"
            )
        finally:
            await transaction.rollback()


async def test_authoritative_dry_run_requires_explicit_sections_and_valid_intent(
    db_pool,
):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            port = await export_hmx(conn, intent="port")
            missing = await dry_run_hmx(conn, port, strategy="authoritative")
            assert not missing.can_import
            assert any(
                item["code"] == "replacement_sections_missing"
                for item in missing.conflicts
            )

            valid = await dry_run_hmx(
                conn,
                port,
                strategy="authoritative",
                replace_sections=["worldview"],
                allow_locally_trusted_lineage=True,
            )
            assert valid.can_import
            assert valid.protected_policy["operations"][0]["disposition"] == (
                "verified_noop_candidate"
            )

            telepathy = copy.deepcopy(port)
            telepathy["export_intent"] = "telepathy"
            invalid = await dry_run_hmx(
                conn,
                telepathy,
                strategy="authoritative",
                replace_sections=["worldview"],
            )
            assert not invalid.can_import
            assert any(
                item["code"] == "invalid_authoritative_intent"
                for item in invalid.conflicts
            )
        finally:
            await transaction.rollback()


def _sign_override(
    private_key,
    *,
    envelope,
    before,
    sections,
    rationale,
    reason_code="agent_paused",
    evidence_ref="report:hmx-override-test",
    operator_identity="test-operator",
):
    operations = [
        {
            "section": section,
            "local_digest_v1": before["section_digests"][section],
            "imported_digest_v1": envelope["section_digests"][section],
        }
        for section in sections
    ]
    payload = operator_override_signing_payload(
        envelope=envelope,
        operations=operations,
        acknowledgement=OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
        reason_code=reason_code,
        evidence_ref=evidence_ref,
        rationale=rationale,
        operator_identity=operator_identity,
    )
    return base64.b64encode(private_key.sign(payload)).decode("ascii")


async def test_verified_operator_override_executes_atomically_and_is_reversible(
    db_pool,
):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            before = await export_hmx(conn, intent="port")
            envelope = copy.deepcopy(before)
            sections = ["worldview", "drives"]
            for section in sections:
                _mutate_section(envelope, section)
            rationale = "Recover protected state while acknowledgement is paused"
            private_key = Ed25519PrivateKey.generate()
            signature = _sign_override(
                private_key,
                envelope=envelope,
                before=before,
                sections=sections,
                rationale=rationale,
            )
            await conn.execute("UPDATE heartbeat_state SET is_paused=TRUE WHERE id=1")

            result = await import_hmx(
                conn,
                envelope,
                strategy="authoritative",
                replace_sections=sections,
                replacement_rationale=rationale,
                verifier=Ed25519TrustAnchors(private_key.public_key()),
                operator_signature=signature,
                operator_identity="test-operator",
                force_replace=True,
                override_acknowledgement=OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
                override_reason_code="agent_paused",
                override_evidence_ref="report:hmx-override-test",
            )

            assert [
                operation["replacement_executor"]
                for operation in result.protected_operations
            ] == ["operator_override", "operator_override"]
            after = await export_hmx(conn, intent="port")
            for section in sections:
                assert (
                    after["section_digests"][section]
                    == envelope["section_digests"][section]
                )
            for operation in result.protected_operations:
                audit = await conn.fetchval(
                    "SELECT record FROM protected_replacement_audit WHERE audit_id=$1",
                    operation["audit_ids"][0],
                )
                audit = json.loads(audit) if isinstance(audit, str) else audit
                assert audit["agent_acknowledgement"] == "bypassed"
                assert audit["replacement_executor"] == "operator_override"
                assert audit["override_reason_code"] == "agent_paused"
                assert audit["override_evidence_ref"] == "report:hmx-override-test"
                assert (
                    audit["operator_override"]["signature_verification"]["status"]
                    == "verified"
                )
                assert audit["reversibility_window"]["heartbeats"] == 7
                assert audit["reversibility_window"]["window_open"] is True
        finally:
            await transaction.rollback()


async def test_operator_override_cannot_bypass_agent_refusal(db_pool):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            before = await export_hmx(conn, intent="port")
            envelope = copy.deepcopy(before)
            _mutate_section(envelope, "worldview")
            rationale = "Proposal the agent will explicitly refuse"
            pending = await import_hmx(
                conn,
                envelope,
                strategy="authoritative",
                replace_sections=["worldview"],
                replacement_rationale=rationale,
                verifier=VerifiedTrustAnchors(),
            )
            replacement_id = pending.protected_operations[0]["replacement_id"]
            await acknowledge_protected_replacement(
                conn,
                replacement_id,
                decision="refuse",
                rationale="This replacement conflicts with current values",
            )
            private_key = Ed25519PrivateKey.generate()
            signature = _sign_override(
                private_key,
                envelope=envelope,
                before=before,
                sections=["worldview"],
                rationale=rationale,
            )
            await conn.execute("UPDATE heartbeat_state SET is_paused=TRUE WHERE id=1")

            with pytest.raises(
                ProtectedReplacementError, match="agent_decision_cannot_be_bypassed"
            ):
                await import_hmx(
                    conn,
                    envelope,
                    strategy="authoritative",
                    replace_sections=["worldview"],
                    replacement_rationale=rationale,
                    verifier=Ed25519TrustAnchors(private_key.public_key()),
                    operator_signature=signature,
                    operator_identity="test-operator",
                    force_replace=True,
                    override_acknowledgement=OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
                    override_reason_code="agent_paused",
                    override_evidence_ref="report:hmx-override-test",
                )

            assert (
                await conn.fetchval(
                    "SELECT status FROM hmx_pending_replacements WHERE replacement_id=$1::uuid",
                    replacement_id,
                )
                == "refused"
            )
            assert (await export_hmx(conn, intent="port"))["section_digests"][
                "worldview"
            ] == before["section_digests"]["worldview"]
        finally:
            await transaction.rollback()


async def test_operator_override_rejects_invalid_signature_and_unobserved_state(
    db_pool,
):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _prepare(conn)
            before = await export_hmx(conn, intent="port")
            envelope = copy.deepcopy(before)
            _mutate_section(envelope, "drives")
            rationale = "Test fail-closed override authorization"
            private_key = Ed25519PrivateKey.generate()
            signature = _sign_override(
                private_key,
                envelope=envelope,
                before=before,
                sections=["drives"],
                rationale=rationale,
            )
            verifier = Ed25519TrustAnchors(private_key.public_key())

            with pytest.raises(
                ProtectedReplacementError, match="override_reason_not_observed"
            ):
                await import_hmx(
                    conn,
                    envelope,
                    strategy="authoritative",
                    replace_sections=["drives"],
                    replacement_rationale=rationale,
                    verifier=verifier,
                    operator_signature=signature,
                    operator_identity="test-operator",
                    force_replace=True,
                    override_acknowledgement=OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
                    override_reason_code="agent_paused",
                    override_evidence_ref="report:hmx-override-test",
                )

            await conn.execute("UPDATE heartbeat_state SET is_paused=TRUE WHERE id=1")
            with pytest.raises(ProtectedReplacementError, match="unverified_signature"):
                await import_hmx(
                    conn,
                    envelope,
                    strategy="authoritative",
                    replace_sections=["drives"],
                    replacement_rationale=rationale,
                    verifier=verifier,
                    operator_signature=base64.b64encode(b"x" * 64).decode("ascii"),
                    operator_identity="test-operator",
                    force_replace=True,
                    override_acknowledgement=OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
                    override_reason_code="agent_paused",
                    override_evidence_ref="report:hmx-override-test",
                )
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 0
            assert (await export_hmx(conn, intent="port"))["section_digests"][
                "drives"
            ] == before["section_digests"]["drives"]
        finally:
            await transaction.rollback()
