"""Pure text helpers for the Hexis TUI — no Textual imports, easy to unit-test.

Covers:
  * ``strip_scaffolding`` — remove leaked model scaffolding (<think>, tool-call
    blocks, special tokens, trace lines) from visible text, capturing the
    reasoning separately. Code-fence-aware and streaming-safe (partial/unclosed
    tags are held back rather than flashed).
  * ``redact`` — mask secrets and home paths before showing tool output.
  * ``format_elapsed`` / ``truncate`` — small formatters.
  * content pools (think-verbs, placeholders) + ``rotating``.
"""
from __future__ import annotations

import re

# ── Scaffolding strip ────────────────────────────────────────────────────────

_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
_THINK_RE = re.compile(r"<think>(.*?)</think>", re.DOTALL | re.IGNORECASE)
_THINK_OPEN_RE = re.compile(r"<think>(.*)$", re.DOTALL | re.IGNORECASE)

_TOOLCALL_RES = [
    re.compile(r"<tool_call>.*?</tool_call>", re.DOTALL | re.IGNORECASE),
    re.compile(r"<function_calls>.*?</function_calls>", re.DOTALL | re.IGNORECASE),
    re.compile(r"<invoke\b.*?</invoke>", re.DOTALL | re.IGNORECASE),
    re.compile(r"</?antml:[^>]*>", re.IGNORECASE),
    re.compile(r"\[TOOL_CALL\].*?\[/TOOL_CALL\]", re.DOTALL | re.IGNORECASE),
]

# Model special tokens: <|im_start|>, <|channel|>, <|end|>, <s>, </s>, …
_SPECIAL_TOKEN_RE = re.compile(r"<\|[^|>]*\|>|</?s>", re.IGNORECASE)

# Internal trace lines the runtime sometimes prints (emoji-prefixed). Kept
# conservative: only lines that clearly look like tool/session traces.
_TRACE_LINE_RE = re.compile(
    r"^[ \t]*(?:\U0001F4CA|\U0001F6E0️?|\U0001F4D6|⚙️?|\U0001F527|\U0001F9E9)"
    r"[ \t]*(?:Session Status|Exec|Read|Tool Call|Tool)\b.*$",
    re.MULTILINE,
)

# A dangling partial tag at the very end of a stream chunk (e.g. "<", "<th",
# "<tool_ca"). Hold it back so it never flashes; the next chunk completes it.
_DANGLING_TAG_RE = re.compile(r"<[a-zA-Z|/!\[]*$")

_FENCE_STASH_RE = re.compile("\x00F(\\d+)\x00")


def strip_scaffolding(text: str) -> tuple[str, str]:
    """Split *text* into (visible, reasoning).

    ``visible`` is the user-facing prose with all scaffolding removed.
    ``reasoning`` is any captured ``<think>`` content (may be empty).
    Safe to call repeatedly on the growing buffer of a streaming response.
    """
    if not text:
        return "", ""

    # 1. Protect complete fenced code blocks so we never strip inside them.
    fences: list[str] = []

    def _stash(m: re.Match[str]) -> str:
        fences.append(m.group(0))
        return f"\x00F{len(fences) - 1}\x00"

    work = _FENCE_RE.sub(_stash, text)

    reasoning: list[str] = []

    # 2. Complete <think>…</think> blocks → reasoning.
    def _grab(m: re.Match[str]) -> str:
        chunk = m.group(1).strip()
        if chunk:
            reasoning.append(chunk)
        return ""

    work = _THINK_RE.sub(_grab, work)

    # 3. Unclosed <think> (still streaming): everything after it is reasoning.
    m = _THINK_OPEN_RE.search(work)
    if m:
        tail = m.group(1).strip()
        if tail:
            reasoning.append(tail)
        work = work[: m.start()]

    # 4. Tool-call blocks + special tokens + trace lines.
    for rx in _TOOLCALL_RES:
        work = rx.sub("", work)
    work = _SPECIAL_TOKEN_RE.sub("", work)
    work = _TRACE_LINE_RE.sub("", work)

    # 5. Trim a trailing partial tag fragment (streaming edge).
    work = _DANGLING_TAG_RE.sub("", work)

    # 6. Restore protected fences.
    def _restore(m: re.Match[str]) -> str:
        return fences[int(m.group(1))]

    visible = _FENCE_STASH_RE.sub(_restore, work)

    # Tidy: collapse 3+ blank lines the strips may have left behind.
    visible = re.sub(r"\n{3,}", "\n\n", visible)
    return visible, "\n".join(reasoning)


# ── Redaction ────────────────────────────────────────────────────────────────

import os as _os

_HOME = _os.path.expanduser("~")

_SECRET_RES = [
    (re.compile(r"(Authorization\s*:\s*)\S+", re.IGNORECASE), r"\1[redacted]"),
    (re.compile(r"(Cookie\s*:\s*)\S+", re.IGNORECASE), r"\1[redacted]"),
    (re.compile(r"\bBearer\s+[A-Za-z0-9._\-]+", re.IGNORECASE), "Bearer [redacted]"),
    (re.compile(r"\b(sk|xai|ghp|gho|pk)-[A-Za-z0-9\-_]{8,}"), "[redacted-key]"),
    (re.compile(r"((?:api[_-]?key|token|password|secret)\s*[=:]\s*)['\"]?[^\s'\"]+",
                re.IGNORECASE), r"\1[redacted]"),
    (re.compile(r"-----BEGIN [A-Z ]+PRIVATE KEY-----.*?-----END [A-Z ]+PRIVATE KEY-----",
                re.DOTALL), "[redacted-private-key]"),
]


def redact(text: str) -> str:
    """Mask secrets and shorten the user's home path before display."""
    if not text:
        return text
    for rx, repl in _SECRET_RES:
        text = rx.sub(repl, text)
    if _HOME and _HOME != "/":
        text = text.replace(_HOME, "~")
    return text


# ── Formatters ───────────────────────────────────────────────────────────────

def format_elapsed(seconds: float) -> str:
    """Human elapsed: ``8s`` / ``2m 13s`` / ``1h 04m``."""
    total = max(0, int(seconds))
    if total < 60:
        return f"{total}s"
    if total < 3600:
        m, s = divmod(total, 60)
        return f"{m}m {s:02d}s"
    h, rem = divmod(total, 3600)
    m = rem // 60
    return f"{h}h {m:02d}m"


def truncate(text: str, limit: int, ellipsis: str = "…") -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: max(0, limit - len(ellipsis))].rstrip() + ellipsis


def rotating(seq: list[str], i: int) -> str:
    """Cycle through *seq* by index (jitter-free, deterministic)."""
    return seq[i % len(seq)] if seq else ""


# ── Content pools ────────────────────────────────────────────────────────────

THINK_VERBS = [
    "pondering", "contemplating", "musing", "reasoning", "reflecting",
    "considering", "synthesizing", "weighing", "recollecting", "deliberating",
]

PLACEHOLDERS = [
    "Ask me anything…",
    "Try \"what do you remember about…\"",
    "Type / for commands",
    "Try \"/recall <topic>\"",
    "Type your message…",
]
