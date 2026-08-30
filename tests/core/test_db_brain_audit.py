from pathlib import Path

from scripts.db_brain_audit import run_audit


def test_db_brain_audit_reports_advisory_findings(tmp_path: Path):
    root = tmp_path
    pkg = root / "services"
    pkg.mkdir()
    (pkg / "example.py").write_text(
        """
async def f(conn):
    enabled = await conn.fetchval("SELECT get_config_bool('x')")
    if enabled:
        await conn.execute("UPDATE memories SET metadata = '{}'::jsonb")
""",
        encoding="utf-8",
    )

    payload = run_audit(root, ("services",))

    assert payload["status"] == "advisory"
    assert payload["finding_count"] >= 2
    assert payload["by_rule"]["config_branching"] >= 1
    assert payload["by_rule"]["direct_domain_sql"] >= 1
