---
name: connector-action-authorization
description: Inspect, grant, and revoke scoped connector action policies for sends, replies, labels, spam triage, and provider state changes
category: communication
requires:
  tools: [connector_action_policy_status, grant_connector_action_policy, revoke_connector_action_policy]
contexts: [chat]
bound_tools: [connector_action_policy_status, grant_connector_action_policy, revoke_connector_action_policy]
---

# Connector Action Authorization

Use this when the user wants Samantha to act through an external connector beyond read-only setup/backfill: sending messages, replying to email, marking messages read, labeling, spam triage, deletion, or cross-channel intervention.

## Principles

- Do not treat a connected account as permission to act. Connection grants access; action policies grant behavior.
- Make the policy concrete before granting it: connector, action kind, target/account, contexts, limits, and expiration when relevant.
- Prefer narrow constraints: `allowed_targets` / `allowed_recipients` and `max_per_day` are safer than broad grants.
- `allow_autonomous: true` means heartbeat or another non-chat context may act without a live user message. Use it only when the user explicitly asks for ongoing/autonomous behavior.
- Keep destructive actions, especially `delete`, out of autonomous policy unless the user is exceptionally explicit and the constraints are narrow.

## Flow

1. Call `connector_action_policy_status` to inspect existing grants.
2. If granting, summarize the proposed scope in normal language before calling `grant_connector_action_policy`.
3. Use `requires_per_action_approval: false` only when the user asks for preauthorization rather than case-by-case approval.
4. Use `revoke_connector_action_policy` when the user asks to remove or narrow a grant.
