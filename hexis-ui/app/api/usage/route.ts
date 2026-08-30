import { NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { summarizeUsageByModel, type UsageSummaryRow } from "@/lib/usage-summary";

type DailyUsageRow = {
  day?: unknown;
  total_cost?: unknown;
  total_tokens?: unknown;
  call_count?: unknown;
};

export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url);
    const period = searchParams.get("period") || "30 days";
    const source = searchParams.get("source") || null;

    const [summaryRows, dailyRows] = await Promise.all([
      prisma.$queryRawUnsafe<UsageSummaryRow[]>(
        "SELECT * FROM usage_summary($1::interval, $2)",
        period,
        source,
      ),
      prisma.$queryRawUnsafe<DailyUsageRow[]>(
        "SELECT * FROM usage_daily($1::interval, $2)",
        period,
        source,
      ),
    ]);

    // usage_summary is operation-grained; the dashboard presents model totals.
    const { byModel, totalCost, totalTokens, totalCalls } = summarizeUsageByModel(
      summaryRows || [],
    );

    // Aggregate daily by date (sum across models)
    const dailyMap = new Map<string, { day: string; cost: number; tokens: number; calls: number }>();
    for (const r of dailyRows || []) {
      const day = String(r.day);
      const existing = dailyMap.get(day);
      const cost = toNum(r.total_cost) ?? 0;
      const tokens = toNum(r.total_tokens) ?? 0;
      const calls = toNum(r.call_count) ?? 0;
      if (existing) {
        existing.cost += cost;
        existing.tokens += tokens;
        existing.calls += calls;
      } else {
        dailyMap.set(day, { day, cost, tokens, calls });
      }
    }
    const daily = Array.from(dailyMap.values()).sort(
      (a, b) => a.day.localeCompare(b.day),
    );

    return NextResponse.json({
      period,
      total_cost_usd: Math.round(totalCost * 100) / 100,
      total_tokens: totalTokens,
      total_calls: totalCalls,
      by_model: byModel,
      daily,
    });
  } catch (error: unknown) {
    console.error("Usage API error:", error);
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Failed to fetch usage data" },
      { status: 500 },
    );
  }
}

function toNum(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
