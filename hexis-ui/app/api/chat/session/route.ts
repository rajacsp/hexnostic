import { NextResponse } from "next/server";

import { normalizeJsonValue } from "@/lib/db";
import { prisma } from "@/lib/prisma";

export const runtime = "nodejs";

type Row = { session: unknown };

function asRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Failed to create chat session";
}

export async function POST(): Promise<Response> {
  try {
    const rows = await prisma.$queryRawUnsafe<Row[]>(
      "SELECT get_or_create_chat_session(NULL::uuid, $1::text, NULL::text, $2::jsonb) AS session",
      "web",
      JSON.stringify({
        source: "web",
        created_by: "user",
        created_at: new Date().toISOString(),
      })
    );
    const session = asRecord(normalizeJsonValue(rows[0]?.session));
    const sessionId = typeof session.session_id === "string" ? session.session_id : null;
    if (!sessionId) {
      return NextResponse.json({ error: "database did not return a session id" }, { status: 500 });
    }
    return NextResponse.json({ ...session, session_id: sessionId });
  } catch (error: unknown) {
    console.error("Chat session create API error:", error);
    return NextResponse.json({ error: errorMessage(error) }, { status: 500 });
  }
}
