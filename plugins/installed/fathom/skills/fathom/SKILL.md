---
name: fathom
description: Fathom meeting transcripts (list and ingest into memory)
category: knowledge
requires:
  tools: [fathom_transcripts]
contexts: [heartbeat, chat]
bound_tools: [fathom_transcripts, fathom_ingest]
---

# Fathom

Use these tools for fathom meeting transcripts (list and ingest into memory). Credentials come from the
environment (FATHOM_API_KEY); when they are missing, say so
plainly and continue without this capability.
