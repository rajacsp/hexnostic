"""HMX Slice 9 protected replacement state machine and durable safety records."""

from __future__ import annotations

import copy
import json
import uuid

import pytest

from core.digest import audit_record_digest_v1, protected_section_digest_v1
from core.memory_exchange import export_hmx, import_hmx
from core.protected_replacement import (
    ProtectedReplacementError,
    acknowledge_protected_replacement,
    create_protected_snapshot,
    evaluate_protected_replacement,
    import_audit_records,
    pending_protected_replacements,
)
from core.trust_anchors import TrustVerification

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


class VerifiedTrustAnchors:
    def verify_operator_signature(self, **kwargs):
        return TrustVerification.accepted(anchor_id="test-operator")

    def verify_source_identity(self, **kwargs):
        return TrustVerification.accepted(anchor_id="test-source")

    def verify_lineage(self, **kwargs):
        return TrustVerification.accepted(anchor_id="test-lineage")


class UnverifiedOperatorTrustAnchors(VerifiedTrustAnchors):
    def verify_operator_signature(self, **kwargs):
        return TrustVerification.unverified("test deployment has no operator key")


class InvalidLineageTrustAnchors(VerifiedTrustAnchors):
    def verify_lineage(self, **kwargs):
        return TrustVerification.invalid(
            "configured lineage proof is invalid", anchor_id="test-lineage"
        )


async def _prepare(conn):
    await conn.execute("LOAD 'age'")
    await conn.execute('SET search_path = public, ag_catalog, "$user"')


async def _seed_worldview(conn) -> str:
    content = f"Slice 9 protected worldview {uuid.uuid4().hex}"
    await conn.execute(
        "INSERT INTO memories "
        "(type, content, embedding, importance, trust_level, status, metadata) "
        "VALUES ('worldview', $1, "
        "array_fill(0.1, ARRAY[embedding_dimension()])::vector, 0.9, 0.95, "
        "'active', $2::jsonb)",
        content,
        json.dumps(
            {
                "category": "value",
                "confidence": 0.95,
                "stability": 0.95,
                "provenance": {"acquisition_mode": "experienced"},
            }
        ),
    )
    return content


async def _envelope(conn):
    return await export_hmx(conn, intent="port")


async def test_phase_zero_is_audited_noop_without_consent_or_snapshot(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            content = await _seed_worldview(conn)
            envelope = await _envelope(conn)
            before = await conn.fetchrow(
                "SELECT id, content, updated_at FROM memories WHERE content=$1", content
            )

            result = await evaluate_protected_replacement(
                conn,
                envelope,
                section="worldview",
                rationale="Verify a content-identical migration",
                verifier=VerifiedTrustAnchors(),
            )

            assert result.disposition == "verified_noop"
            assert not result.agent_acknowledgement_required
            assert len(result.audit_ids) == 1
            after = await conn.fetchrow(
                "SELECT id, content, updated_at FROM memories WHERE id=$1", before["id"]
            )
            assert dict(after) == dict(before)
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 0
            assert (
                await conn.fetchval("SELECT count(*) FROM hmx_pending_replacements")
                == 0
            )
            assert (
                await conn.fetchval(
                    "SELECT count(*) FROM protected_replacement_snapshots"
                )
                == 0
            )
            audit = await conn.fetchval(
                "SELECT record FROM protected_replacement_audit WHERE audit_id=$1",
                result.audit_ids[0],
            )
            audit = json.loads(audit) if isinstance(audit, str) else audit
            assert audit["event_type"] == "protected_section_verified"
            assert audit["lineage_verification"]["status"] == "verified"

            exported = await _envelope(conn)
            records = exported["sections"]["audit_records"]
            assert any(
                item["audit_id"] == result.audit_ids[0]
                for item in records["protected_section_verified_audit"]
            )
        finally:
            await transaction.rollback()


async def test_phase_zero_audit_failure_rolls_back_and_fails_closed(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            envelope = await _envelope(conn)
            await conn.execute(
                "CREATE FUNCTION pg_temp.reject_hmx_audit() RETURNS trigger AS $$ "
                "BEGIN RAISE EXCEPTION 'forced audit failure'; END; $$ LANGUAGE plpgsql"
            )
            await conn.execute(
                "CREATE TRIGGER test_reject_hmx_audit BEFORE INSERT ON "
                "protected_replacement_audit FOR EACH ROW EXECUTE FUNCTION "
                "pg_temp.reject_hmx_audit()"
            )

            with pytest.raises(
                ProtectedReplacementError, match="verified_audit_write_failure"
            ):
                await evaluate_protected_replacement(
                    conn,
                    envelope,
                    section="worldview",
                    rationale="Exercise fail-closed audit behavior",
                    verifier=VerifiedTrustAnchors(),
                )
            assert (
                await conn.fetchval("SELECT count(*) FROM protected_replacement_audit")
                == 0
            )
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 0
        finally:
            await transaction.rollback()


async def test_unverified_lineage_requires_explicit_local_trust_or_acknowledgement(
    db_pool,
):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            envelope = await _envelope(conn)
            pending = await evaluate_protected_replacement(
                conn,
                envelope,
                section="worldview",
                rationale="No trust anchor is configured",
            )
            assert pending.disposition == "pending_acknowledgement"
            assert {item["code"] for item in pending.conflicts} == {
                "unverified_lineage"
            }
            assert pending.agent_acknowledgement_required

            trusted = await evaluate_protected_replacement(
                conn,
                envelope,
                section="drives",
                rationale="Explicitly trust matching local lineage labels",
                allow_locally_trusted_lineage=True,
            )
            assert trusted.disposition == "verified_noop"
            record = await conn.fetchval(
                "SELECT record FROM protected_replacement_audit WHERE audit_id=$1",
                trusted.audit_ids[0],
            )
            record = json.loads(record) if isinstance(record, str) else record
            assert record["lineage_verification"]["locally_trusted_label"] is True
            assert record["lineage_verification"]["status"] == "unverified"
        finally:
            await transaction.rollback()


async def test_digest_tamper_is_rejected_before_protocol_state_is_created(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            envelope = await _envelope(conn)
            envelope["sections"]["worldview"][0]["content"] += " tampered"
            with pytest.raises(
                ProtectedReplacementError, match="protected_section_digest_invalid"
            ):
                await evaluate_protected_replacement(
                    conn,
                    envelope,
                    section="worldview",
                    rationale="This request has a stale digest",
                    verifier=VerifiedTrustAnchors(),
                )
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 0
            assert (
                await conn.fetchval("SELECT count(*) FROM hmx_pending_replacements")
                == 0
            )
        finally:
            await transaction.rollback()


async def test_missing_protocol_capability_is_refused_before_state_creation(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = await _envelope(conn)
            envelope["capabilities"]["optional_features"].remove(
                "protected_replacement_protocol_v1"
            )
            with pytest.raises(
                ProtectedReplacementError,
                match="protected_replacement_capability_missing",
            ):
                await evaluate_protected_replacement(
                    conn,
                    envelope,
                    section="drives",
                    rationale="Unsupported replacement must stop",
                    verifier=VerifiedTrustAnchors(),
                )
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 0
        finally:
            await transaction.rollback()


async def test_subset_scope_is_parseable_but_refused_with_recovery_path(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = await _envelope(conn)
            with pytest.raises(
                ProtectedReplacementError,
                match="whole_section or deliberative import",
            ):
                await evaluate_protected_replacement(
                    conn,
                    envelope,
                    section="worldview",
                    scope_mode="subset",
                    rationale="A subset request must not silently widen its scope",
                    verifier=VerifiedTrustAnchors(),
                )
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 0
        finally:
            await transaction.rollback()


async def test_lineage_integrity_failure_requires_operator_override(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            envelope = await _envelope(conn)
            result = await evaluate_protected_replacement(
                conn,
                envelope,
                section="worldview",
                rationale="Reject an invalid proof even when lineage labels match",
                verifier=InvalidLineageTrustAnchors(),
            )

            assert {item["code"] for item in result.conflicts} == {
                "lineage_integrity_failure"
            }
            with pytest.raises(
                ProtectedReplacementError,
                match="lineage_integrity_failure_requires_operator_override",
            ):
                await acknowledge_protected_replacement(
                    conn, result.replacement_id, decision="accept"
                )
            assert (
                await conn.fetchval(
                    "SELECT status FROM hmx_pending_replacements "
                    "WHERE replacement_id=$1::uuid",
                    result.replacement_id,
                )
                == "pending"
            )
        finally:
            await transaction.rollback()


async def test_unverified_operator_signature_is_discarded_and_reported(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = await _envelope(conn)
            envelope["sections"]["drives"][0]["current_level"] += 0.1
            envelope["section_digests"]["drives"] = protected_section_digest_v1(
                "drives", envelope["sections"]["drives"]
            )
            result = await evaluate_protected_replacement(
                conn,
                envelope,
                section="drives",
                rationale="Signature cannot be trusted in this deployment",
                verifier=UnverifiedOperatorTrustAnchors(),
                operator_signature="unverifiable-claim",
                operator_identity="operator@example.test",
            )
            assert "unverified_signature" in {
                conflict["code"] for conflict in result.conflicts
            }
            consent = await conn.fetchrow(
                "SELECT operator_signature, operator_identity, trust_verification "
                "FROM hmx_consent WHERE consent_id=$1::uuid",
                result.consent_id,
            )
            assert consent["operator_signature"] is None
            assert consent["operator_identity"] == "operator@example.test"
            trust = consent["trust_verification"]
            trust = json.loads(trust) if isinstance(trust, str) else trust
            assert trust["operator_signature_verification"]["status"] == "unverified"
        finally:
            await transaction.rollback()


async def test_divergence_queues_once_and_refusal_cannot_be_bypassed_by_retry(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            envelope = await _envelope(conn)
            envelope["sections"]["worldview"][0]["content"] += " revised"
            envelope["section_digests"]["worldview"] = protected_section_digest_v1(
                "worldview", envelope["sections"]["worldview"]
            )

            first = await evaluate_protected_replacement(
                conn,
                envelope,
                section="worldview",
                rationale="Propose a materially revised worldview",
                verifier=VerifiedTrustAnchors(),
            )
            second = await evaluate_protected_replacement(
                conn,
                envelope,
                section="worldview",
                rationale="Propose a materially revised worldview",
                verifier=VerifiedTrustAnchors(),
            )
            assert first.disposition == "pending_acknowledgement"
            assert {item["code"] for item in first.conflicts} == {
                "protected_section_digest_mismatch"
            }
            assert second.reused
            assert second.replacement_id == first.replacement_id
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 1
            consent = await conn.fetchrow(
                "SELECT sections, source, replacement_scope, rationale "
                "FROM hmx_consent WHERE consent_id=$1::uuid",
                first.consent_id,
            )
            source = (
                json.loads(consent["source"])
                if isinstance(consent["source"], str)
                else consent["source"]
            )
            scope = (
                json.loads(consent["replacement_scope"])
                if isinstance(consent["replacement_scope"], str)
                else consent["replacement_scope"]
            )
            assert consent["sections"] == ["worldview"]
            assert source["export_id"] == envelope["export_id"]
            assert scope == {
                "section": "worldview",
                "mode": "whole_section",
                "selector": None,
            }
            assert consent["rationale"] == "Propose a materially revised worldview"

            refused = await acknowledge_protected_replacement(
                conn,
                first.replacement_id,
                decision="refuse",
                rationale="This conflicts with settled boundaries",
            )
            assert refused["status"] == "refused"
            with pytest.raises(Exception, match="already refused"):
                await acknowledge_protected_replacement(
                    conn, first.replacement_id, decision="accept"
                )
            replay = await evaluate_protected_replacement(
                conn,
                envelope,
                section="worldview",
                rationale="Propose a materially revised worldview",
                verifier=VerifiedTrustAnchors(),
            )
            assert replay.reused
            assert replay.replacement_id == first.replacement_id
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 1
        finally:
            await transaction.rollback()


async def test_acknowledgement_supports_defer_and_modification_request(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            envelope = await _envelope(conn)
            envelope["sections"]["drives"][0]["current_level"] += 0.1
            envelope["section_digests"]["drives"] = protected_section_digest_v1(
                "drives", envelope["sections"]["drives"]
            )
            result = await evaluate_protected_replacement(
                conn,
                envelope,
                section="drives",
                rationale="Exercise the non-final acknowledgement decisions",
                verifier=VerifiedTrustAnchors(),
            )

            deferred = await acknowledge_protected_replacement(
                conn,
                result.replacement_id,
                decision="defer",
                rationale="Review this after another heartbeat",
            )
            assert deferred["status"] == "deferred"
            modified = await acknowledge_protected_replacement(
                conn,
                result.replacement_id,
                decision="request_modification",
                rationale="Keep the current baseline",
                proposed_changes={"current_level": "unchanged"},
            )
            assert modified["status"] == "modification_requested"
        finally:
            await transaction.rollback()


async def test_acknowledgement_timeout_uses_later_of_both_limits(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            envelope = await _envelope(conn)
            envelope["sections"]["drives"][0]["current_level"] += 0.1
            envelope["section_digests"]["drives"] = protected_section_digest_v1(
                "drives", envelope["sections"]["drives"]
            )
            result = await evaluate_protected_replacement(
                conn,
                envelope,
                section="drives",
                rationale="Exercise acknowledgement timeout",
                verifier=VerifiedTrustAnchors(),
            )
            await conn.execute(
                "UPDATE hmx_pending_replacements SET timeout_at=CURRENT_TIMESTAMP-INTERVAL '1 second' "
                "WHERE replacement_id=$1::uuid",
                result.replacement_id,
            )
            assert await conn.fetchval("SELECT hmx_expire_pending_replacements()") == 0
            assert (await pending_protected_replacements(conn))["total"] == 1

            await conn.execute(
                "UPDATE heartbeat_state SET heartbeat_count=heartbeat_count+10 WHERE id=1"
            )
            assert await conn.fetchval("SELECT hmx_expire_pending_replacements()") == 1
            assert (await pending_protected_replacements(conn))["total"] == 0
            assert (
                await conn.fetchval(
                    "SELECT status FROM hmx_pending_replacements WHERE replacement_id=$1::uuid",
                    result.replacement_id,
                )
                == "timed_out"
            )

            resubmitted = await evaluate_protected_replacement(
                conn,
                envelope,
                section="drives",
                rationale="Exercise acknowledgement timeout",
                verifier=VerifiedTrustAnchors(),
            )
            replay = await evaluate_protected_replacement(
                conn,
                envelope,
                section="drives",
                rationale="Exercise acknowledgement timeout",
                verifier=VerifiedTrustAnchors(),
            )
            assert resubmitted.replacement_id != result.replacement_id
            assert not resubmitted.reused
            assert replay.reused
            assert replay.replacement_id == resubmitted.replacement_id
            assert await conn.fetchval("SELECT count(*) FROM hmx_consent") == 2
        finally:
            await transaction.rollback()


async def test_snapshot_window_closes_on_earlier_heartbeat_limit(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            snapshot_id = await create_protected_snapshot(
                conn, ["worldview"], heartbeat_window=2
            )
            window = await conn.fetchval(
                "SELECT hmx_snapshot_window($1::uuid)", snapshot_id
            )
            window = json.loads(window) if isinstance(window, str) else window
            assert window["window_open"] is True

            await conn.execute(
                "UPDATE heartbeat_state SET heartbeat_count=heartbeat_count+2 WHERE id=1"
            )
            assert (
                await conn.fetchval("SELECT hmx_purge_expired_protected_snapshots()")
                == 1
            )
            row = await conn.fetchrow(
                "SELECT snapshot_state, purged_at, purge_reason "
                "FROM protected_replacement_snapshots WHERE snapshot_id=$1::uuid",
                snapshot_id,
            )
            assert row["snapshot_state"] is None
            assert row["purged_at"] is not None
            assert row["purge_reason"] == "heartbeat_window_expired"
        finally:
            await transaction.rollback()


async def test_snapshot_window_closes_independently_on_wall_clock_limit(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            snapshot_id = await create_protected_snapshot(
                conn, ["worldview"], heartbeat_window=100
            )
            await conn.execute(
                "UPDATE protected_replacement_snapshots SET "
                "created_at=CURRENT_TIMESTAMP-INTERVAL '2 days', "
                "wall_clock_expires_at=CURRENT_TIMESTAMP-INTERVAL '1 day' "
                "WHERE snapshot_id=$1::uuid",
                snapshot_id,
            )

            assert (
                await conn.fetchval("SELECT hmx_purge_expired_protected_snapshots()")
                == 1
            )
            row = await conn.fetchrow(
                "SELECT snapshot_state, consumed_at, purged_at, purge_reason "
                "FROM protected_replacement_snapshots WHERE snapshot_id=$1::uuid",
                snapshot_id,
            )
            assert row["snapshot_state"] is None
            assert row["consumed_at"] is None
            assert row["purged_at"] is not None
            assert row["purge_reason"] == "wall_clock_expired"
        finally:
            await transaction.rollback()


async def test_audit_dedupe_round_trip_and_append_only_records(db_pool):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_worldview(conn)
            envelope = await _envelope(conn)
            verified = await evaluate_protected_replacement(
                conn,
                envelope,
                section="worldview",
                rationale="Create portable verified history",
                verifier=VerifiedTrustAnchors(),
            )
            portable = await _envelope(conn)
            audit_only = copy.deepcopy(portable)
            audit_only["sections"] = {
                "audit_records": portable["sections"]["audit_records"]
            }
            imported = await import_hmx(conn, audit_only, strategy="additive")
            assert imported.inserted["audit_records"] == 0
            assert not any(
                warning.get("section") == "audit_records"
                and warning.get("code") == "unsupported_section"
                for warning in imported.warnings
            )

            divergent = copy.deepcopy(audit_only)
            record = divergent["sections"]["audit_records"][
                "protected_section_verified_audit"
            ][0]
            record["sections_verified"] = ["identity"]
            conflict = await import_audit_records(conn, divergent)
            assert conflict.conflicts[0]["code"] == "audit_integrity_conflict"

            savepoint = conn.transaction()
            await savepoint.start()
            with pytest.raises(Exception, match="append-only"):
                await conn.execute(
                    "UPDATE protected_replacement_audit SET event_time=CURRENT_TIMESTAMP "
                    "WHERE audit_id=$1",
                    verified.audit_ids[0],
                )
            await savepoint.rollback()
            assert (
                await conn.fetchval(
                    "SELECT (hexis_instance_is_empty()->>'is_empty')::boolean"
                )
                is False
            )
        finally:
            await transaction.rollback()


async def test_empty_target_diagnostics_distinguish_all_protected_audit_types(
    db_pool,
):
    async with db_pool.acquire() as conn:
        await _prepare(conn)
        transaction = conn.transaction()
        await transaction.start()
        try:
            expected = {
                "protected_section_replacement",
                "protected_section_verified",
                "protected_section_reverted",
            }
            for event_type in sorted(expected):
                audit_id = f"acceptance-{event_type}-{uuid.uuid4().hex}"
                record = {"audit_id": audit_id, "event_type": event_type}
                await conn.execute(
                    "INSERT INTO protected_replacement_audit "
                    "(audit_id, event_type, event_time, record, record_digest_v1) "
                    "VALUES ($1, $2, CURRENT_TIMESTAMP, $3::jsonb, $4)",
                    audit_id,
                    event_type,
                    json.dumps(record),
                    audit_record_digest_v1(record),
                )

            state = await conn.fetchval("SELECT hexis_instance_is_empty()")
            state = json.loads(state) if isinstance(state, str) else state
            audit_blockers = [
                blocker
                for blocker in state["blockers"]
                if blocker["kind"] == "protected_audit"
                and blocker["event_type"] in expected
            ]

            assert state["is_empty"] is False
            assert {blocker["event_type"] for blocker in audit_blockers} == expected
            assert all(blocker["count"] >= 1 for blocker in audit_blockers)
        finally:
            await transaction.rollback()
