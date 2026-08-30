"""Credential-free LLM identity resolution shared by runtime and discovery."""

from core.llm_config import configured_llm_identity


def test_codex_default_model_matches_runtime_contract():
    assert configured_llm_identity({"provider": "openai-codex"}) == {
        "provider": "openai-codex",
        "model": "gpt-5.2",
    }


def test_explicit_model_and_normalized_provider_win():
    assert configured_llm_identity(
        {"provider": "openai_chat_completions_endpoint", "model": "local/reasoner"}
    ) == {
        "provider": "openai-chat-completions-endpoint",
        "model": "local/reasoner",
    }
