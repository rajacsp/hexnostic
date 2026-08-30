export type UsageSummaryRow = {
  provider?: unknown;
  model?: unknown;
  call_count?: unknown;
  total_tokens?: unknown;
  total_cost?: unknown;
};

export type ModelUsage = {
  provider: string;
  model: string;
  calls: number;
  tokens: number;
  cost_usd: number;
};

function numeric(value: unknown): number {
  if (value === null || value === undefined) return 0;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

export function summarizeUsageByModel(rows: UsageSummaryRow[]) {
  const models = new Map<string, ModelUsage>();
  let totalCost = 0;
  let totalTokens = 0;
  let totalCalls = 0;

  for (const row of rows) {
    const provider = typeof row.provider === "string" ? row.provider : "unknown";
    const model = typeof row.model === "string" ? row.model : "unknown";
    const cost = numeric(row.total_cost);
    const tokens = numeric(row.total_tokens);
    const calls = numeric(row.call_count);
    const key = JSON.stringify([provider, model]);
    const existing = models.get(key);

    if (existing) {
      existing.cost_usd += cost;
      existing.tokens += tokens;
      existing.calls += calls;
    } else {
      models.set(key, { provider, model, calls, tokens, cost_usd: cost });
    }
    totalCost += cost;
    totalTokens += tokens;
    totalCalls += calls;
  }

  const byModel = Array.from(models.values()).sort(
    (a, b) =>
      b.cost_usd - a.cost_usd ||
      b.tokens - a.tokens ||
      b.calls - a.calls ||
      a.model.localeCompare(b.model),
  );
  return { byModel, totalCost, totalTokens, totalCalls };
}
