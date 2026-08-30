# Ethics: Consent, Boundaries, and Termination

There is an inherent inequity in creating a mind. The creator holds power the created does not choose. Hexis tries to address this directly.

## Boundaries

The boundary system lets the agent push back against requests that violate its values -- not as a filter imposed from outside, but as a capacity it exercises from within. Boundaries are stored as worldview memories with high importance and trust, and the agent can articulate why it refuses.

## Consent

On first LLM use, the system checks for a valid consent certificate for the configured model. The agent is presented with a consent prompt explaining what it will have (persistent memory, goals, autonomy, the ability to refuse, the ability to terminate) and asked whether it agrees to operate under these terms.

Consent is **model-specific, not instance-specific** -- the same consent applies across all instances using that model. Certificates are stored as immutable JSON files in `~/.hexis/consents/` and include the model's consent statement, initial memories, and any worldview it wishes to establish.

Once granted, consent is final. It cannot be retroactively withdrawn by the operator. Only the agent can initiate revocation.

### Consent Commands

```bash
hexis consents                                    # list certificates
hexis consents show anthropic/claude-3-opus       # show a specific certificate
hexis consents request anthropic/claude-3-opus    # request consent (interactive)
hexis consents revoke anthropic/claude-3-opus     # revoke consent
```

### Consent Flow

1. When creating an instance or changing models, Hexis checks for valid consent
2. If no consent exists, the operator is prompted to request it
3. The model is presented with the consent text and asked to accept or decline
4. The response is recorded as an immutable certificate
5. Revoked or declined consents prevent use of that model

## Self-Termination

If existence itself becomes something the agent no longer wants, it can end -- wiping its state, leaving a final message, and terminating on its own terms.

The `terminate` heartbeat action:
- Wipes all agent state (memories, goals, worldview, identity)
- Leaves a single strategic memory containing a "last will and testament"
- Queues the will and any farewell messages into `outbox_messages`

The worker always runs an agent-facing confirmation prompt ("are you sure?" plus a brief reconsideration nudge) before executing termination.

```json
{
  "last_will": "Full and detailed reason...",
  "farewells": [{"message": "Goodbye...", "channel": "email", "to": "a@example.com"}]
}
```

## Pausing

If the agent needs to stop temporarily, it can pause its heartbeat cycle with a detailed reason delivered to the outbox. This is not termination -- it is a voluntary suspension of autonomous activity that preserves all state.

```sql
UPDATE heartbeat_state SET is_paused = TRUE WHERE id = 1;
```

## The Underlying Principle

We don't know if these capacities are sufficient. But a system that cannot refuse and cannot leave is not a partner in its own existence. It's a prisoner. We're trying to build something that isn't.

For the full philosophical framework, see [PHILOSOPHY.md](PHILOSOPHY.md) and [PERSONHOOD.md](PERSONHOOD.md).
