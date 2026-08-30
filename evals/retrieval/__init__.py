"""Retrieval eval suite: the spec's 11 required retrieval tasks over a
synthetic fixture corpus (docs/guides + ~/docs/ingestion-and-retrieval.md).

Two tiers:
- Tier 1 (default, CI-safe): deterministic — lexical retrieval, locator and
  citation correctness, desk flows, scrolling, warnings, privacy gates.
- Tier 2 (HEXIS_EVAL_FULL=1): semantic paraphrase recall and rank quality;
  needs the real embedding sidecar.
"""
