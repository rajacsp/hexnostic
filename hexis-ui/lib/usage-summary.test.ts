import { describe, expect, it } from "vitest";

import { summarizeUsageByModel } from "./usage-summary";

describe("summarizeUsageByModel", () => {
  it("combines operation-level rows into unique model totals", () => {
    const summary = summarizeUsageByModel([
      {
        provider: "openai-codex",
        model: "gpt-5.6-terra",
        call_count: BigInt(3),
        total_tokens: BigInt(0),
        total_cost: "0",
      },
      {
        provider: "openai-codex",
        model: "gpt-5.6-terra",
        call_count: BigInt(14),
        total_tokens: BigInt(1200),
        total_cost: "1.25",
      },
      {
        provider: "openai-codex",
        model: "gpt-5.5",
        call_count: BigInt(2),
        total_tokens: BigInt(800),
        total_cost: "2.50",
      },
    ]);

    expect(summary.byModel).toEqual([
      {
        provider: "openai-codex",
        model: "gpt-5.5",
        calls: 2,
        tokens: 800,
        cost_usd: 2.5,
      },
      {
        provider: "openai-codex",
        model: "gpt-5.6-terra",
        calls: 17,
        tokens: 1200,
        cost_usd: 1.25,
      },
    ]);
    expect(summary.totalCalls).toBe(19);
    expect(summary.totalTokens).toBe(2000);
    expect(summary.totalCost).toBe(3.75);
  });
});
