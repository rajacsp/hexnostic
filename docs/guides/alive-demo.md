<!--
title: Capability Proof and Maturity
summary: Prove Hexis core behavior without retaining demo state, then inspect live deployment maturity
read_when:
  - "You want to verify that Hexis is alive end to end"
  - "You want evidence-based capability maturity and next steps"
section: guides
-->

# Capability Proof and Maturity

Hexis separates an ephemeral capability proof from evidence about how much a
deployment has actually exercised.

## Prove the Core Paths

Run:

```bash
hexis demo
```

The command drives the real database paths for:

- exact recall across two independent sessions;
- refusal of a tool restricted by a worldview boundary;
- agent-loop shutdown at its energy budget;
- generation of a due heartbeat;
- creation of a self-initiated heartbeat decision intent.

All proof data and heartbeat changes live under one outer transaction. The
command rolls that transaction back, searches for its unique marker, compares
heartbeat state before and after, and fails if anything survived.

The proof does not call an LLM and reports zero token cost. It proves that Hexis
can generate the autonomous decision intent, not that the configured provider
can answer it. Check the provider separately and explicitly:

```bash
hexis doctor --llm
```

If initialization is incomplete, heartbeat and self-initiation fail with the
next command to run; the independent recall, boundary, energy, and cleanup
proofs still report their own results.

Use `hexis demo --json` for automation. A nonzero exit means at least one proof
failed.

## Score Deployment Maturity

Run:

```bash
hexis maturity
```

The scorecard reads current schema, configuration, and runtime evidence without
changing anything. Each scenario uses this scale:

| Level | Meaning |
|-------|---------|
| 0 | Capability is unavailable |
| 1 | Implementation is installed |
| 2 | Deployment is configured or has durable state |
| 3 | Capability is operational with live prerequisites |
| 4 | The end-to-end behavior has been observed in durable runtime evidence |

The overall percentage is the sum of live levels divided by the maximum. It is
not a product grade. A deliberately disabled feature, such as background skill
review, remains at configured maturity until the user opts in and applies an
evidence-backed proposal.

Every scenario below level 4 includes one concrete next step. Use
`hexis maturity --json` for CI, fleet reporting, or longitudinal measurement.
