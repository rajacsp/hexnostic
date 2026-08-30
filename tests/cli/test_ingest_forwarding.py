import pytest


pytestmark = [pytest.mark.cli]


def test_hexis_ingest_inserts_default_subcommand_for_flags(monkeypatch):
    """
    `hexis ingest` forwards to `python -m services.ingest`, which expects a subcommand.
    For UX/backwards-compat, `hexis ingest --file foo.md` should behave like
    `python -m services.ingest ingest --file foo.md`.
    """
    from apps import hexis_cli

    captured: dict[str, object] = {}

    def fake_run_module(module: str, argv: list[str]) -> int:
        captured["module"] = module
        captured["argv"] = list(argv)
        return 0

    monkeypatch.setattr(hexis_cli, "_run_module", fake_run_module)

    rc = hexis_cli.main(["ingest", "--file", "doc.md"])
    assert rc == 0
    assert captured["module"] == "services.ingest"
    assert captured["argv"] == ["ingest", "--file", "doc.md"]


def test_hexis_ingest_does_not_modify_explicit_subcommands(monkeypatch):
    from apps import hexis_cli

    captured: dict[str, object] = {}

    def fake_run_module(module: str, argv: list[str]) -> int:
        captured["module"] = module
        captured["argv"] = list(argv)
        return 0

    monkeypatch.setattr(hexis_cli, "_run_module", fake_run_module)

    rc = hexis_cli.main(["ingest", "status", "--pending"])
    assert rc == 0
    assert captured["argv"] == ["status", "--pending"]


def test_hexis_ingest_does_not_infer_subcommand_for_help(monkeypatch):
    from apps import hexis_cli

    captured: dict[str, object] = {}

    def fake_run_module(module: str, argv: list[str]) -> int:
        captured["module"] = module
        captured["argv"] = list(argv)
        return 0

    monkeypatch.setattr(hexis_cli, "_run_module", fake_run_module)

    rc = hexis_cli.main(["ingest", "--help"])
    assert rc == 0
    assert captured["argv"] == ["--help"]


def test_hexis_ingest_strips_double_dash_then_infers_subcommand(monkeypatch):
    from apps import hexis_cli

    captured: dict[str, object] = {}

    def fake_run_module(module: str, argv: list[str]) -> int:
        captured["module"] = module
        captured["argv"] = list(argv)
        return 0

    monkeypatch.setattr(hexis_cli, "_run_module", fake_run_module)

    rc = hexis_cli.main(["ingest", "--", "--file", "doc.md"])
    assert rc == 0
    assert captured["argv"] == ["ingest", "--file", "doc.md"]

