import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { normalizeJsonValue } from "@/lib/db";

type DbRow = Record<string, unknown>;

/**
 * Decide a resource request (#84) from the dashboard: body
 * { id: string, decision: "granted" | "denied", note?: string }.
 * The DB applies the effect (granted config changes go through set_config
 * and the change journal); the agent sees the decision at her next
 * heartbeat.
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const id = typeof body?.id === "string" ? body.id.trim() : "";
    const decision = typeof body?.decision === "string" ? body.decision : "";
    const note =
      typeof body?.note === "string" && body.note.trim() ? body.note.trim() : null;
    if (!id) {
      return NextResponse.json({ error: "id is required" }, { status: 422 });
    }
    if (decision !== "granted" && decision !== "denied") {
      return NextResponse.json(
        { error: "decision must be 'granted' or 'denied'" },
        { status: 422 }
      );
    }
    const rows = await prisma.$queryRawUnsafe<DbRow[]>(
      "SELECT decide_resource_request($1::uuid, $2, $3, NULL) AS result",
      id,
      decision,
      note
    );
    const result = normalizeJsonValue(rows[0]?.result) || {};
    return NextResponse.json(result);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Failed to decide request";
    return NextResponse.json({ error: message }, { status: 400 });
  }
}
