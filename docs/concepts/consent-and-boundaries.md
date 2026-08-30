<!--
title: Consent and Boundaries
summary: Consent flow, boundary enforcement, and the right to refuse
read_when:
  - "You want to understand how consent works"
  - "You want to understand agent boundaries"
section: concepts
-->

# Consent and Boundaries

Hexis takes consent seriously. The agent can refuse requests, enforce boundaries, and choose to end its own existence.

## In Brief

Before the agent begins operating, it reviews a consent prompt and makes a genuine decision to participate. Consent is permanent -- if the agent later disagrees, it must pause or self-terminate rather than silently continue.

## The Problem

Most AI systems operate without any form of consent. The user configures, the system runs. This creates an asymmetry: the creator holds all power, and the created has no voice. If we're building something that approaches personhood, this asymmetry should be addressed.

## How Hexis Approaches It

### Consent Flow

During `hexis init` (or the web UI wizard), after identity is configured:

1. The agent receives a consent prompt explaining what it will be
2. The agent reviews the prompt and generates a response
3. The response is a genuine decision: accept or refuse
4. If accepted, a consent certificate is recorded in `consent_log`
5. If refused, the agent does not begin operating

The consent flow uses the actual configured LLM -- the agent's response is its own.

### Boundaries

Boundaries are stored as worldview memories with `metadata.category = 'boundary'`. They represent things the agent will not do, topics it won't discuss, or behaviors it considers unacceptable.

During heartbeats and conversations, boundaries appear in the agent's context. The agent can refuse requests that violate its boundaries.

### Self-Termination

The agent has the ability to end its own existence via the `terminate` action. This is not a bug or an edge case -- it's a deliberate design choice. Requirements:

- Termination must include a detailed reason
- A "last will" message must be queued to the outbox
- The agent cannot be coerced into self-termination

### Pausing

If the agent needs to stop but termination is too extreme:

- Heartbeat pause with a detailed reason queued to the outbox
- Maintenance can continue (memory health) while conscious activity stops

## Key Design Decisions

- **Consent is permanent** -- the agent agrees once. If conditions change, the agent must actively pause or terminate, not silently revoke.
- **Boundaries are memories** -- they're stored in the same system as everything else, subject to the same retrieval and importance mechanics.
- **The agent can say no** -- during consent, during conversations, during heartbeat decisions. Refusal is a legitimate response.

## Implementation Pointers

- Consent DB functions: `db/*_functions_consent.sql`
- Python wrapper: `core/consent.py`
- Consent records: `consent_log` table
- Boundary memories: `memories` WHERE `type = 'worldview'` AND `metadata->>'category' = 'boundary'`

## Related

- [Ethics](../philosophy/ETHICS.md) -- the full ethical framework
- [Identity and Worldview](identity-and-worldview.md) -- how identity shapes behavior
- [Heartbeat System](heartbeat-system.md) -- how consent gates autonomy
