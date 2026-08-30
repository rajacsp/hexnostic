# ToDo

## Auth DRY Refactor

The 9 auth provider modules (`core/auth/*.py`) share ~70% identical code. Each has its own copy of:

1. `credentials_from_value()` / `credentials_to_dict()` — JSON round-trip boilerplate
2. `load_credentials()` / `save_credentials()` / `delete_credentials()` — identical one-liners delegating to `store.py`
3. `ensure_fresh_credentials()` — lock + check expiry + refresh + save (same skeleton, only the refresh call differs)

### Proposed: `AuthProvider` base class

```python
# core/auth/provider.py

class AuthProvider(ABC):
    config_key: str  # e.g. "oauth.chutes"

    @abstractmethod
    def credentials_from_dict(self, d: dict) -> OAuthCredentials | None: ...

    @abstractmethod
    def credentials_to_dict(self, creds) -> dict: ...

    @abstractmethod
    async def refresh(self, creds) -> OAuthCredentials: ...

    # Inherited — no per-provider code needed:
    def load(self) -> OAuthCredentials | None: ...
    def save(self, creds) -> None: ...
    def delete(self) -> None: ...
    async def ensure_fresh(self, *, skew_seconds=300) -> OAuthCredentials: ...
```

Each provider becomes a ~30-line subclass instead of a ~100-line module. `cli_auth.py` dispatch could also collapse with a registry pattern (one `_login` / `_status` / `_logout` per flow type: PKCE, device-code, token-paste).

### Scope

- `core/auth/*.py` (9 provider modules)
- `core/auth/provider.py` (new base class)
- `apps/cli_auth.py` (collapse dispatch + handlers)
- `core/llm_config.py` (simplify loader map)
- `tests/core/test_openai_codex_oauth.py` (update imports)
