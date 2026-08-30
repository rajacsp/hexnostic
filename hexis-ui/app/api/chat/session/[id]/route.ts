import { NextResponse } from "next/server";

import { normalizeJsonValue } from "@/lib/db";
import { prisma } from "@/lib/prisma";

export const runtime = "nodejs";

type Row = { session: unknown };
type ClearRow = { cleared: unknown };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function asRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Failed to hydrate chat session";
}

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
): Promise<Response> {
  const { id } = await params;
  if (!UUID_RE.test(id)) {
    return NextResponse.json({ error: "session id must be a UUID" }, { status: 422 });
  }

  try {
    const rows = await prisma.$queryRawUnsafe<Row[]>(
      "SELECT hydrate_chat_session($1::uuid) AS session",
      id
    );
    const session = asRecord(normalizeJsonValue(rows[0]?.session));
    return NextResponse.json({
      ...session,
      session_id: typeof session.session_id === "string" ? session.session_id : id,
      messages: asArray(session.messages),
    });
  } catch (error: unknown) {
    console.error("Chat session hydrate API error:", error);
    return NextResponse.json({ error: errorMessage(error) }, { status: 500 });
  }
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> }
): Promise<Response> {
  const { id } = await params;
  if (!UUID_RE.test(id)) {
    return NextResponse.json({ error: "session id must be a UUID" }, { status: 422 });
  }

  let body: Record<string, unknown> = {};
  try {
    body = asRecord(await request.json());
  } catch {
    body = {};
  }

  const action = typeof body.action === "string" ? body.action : "clear_context";
  if (action !== "clear_context") {
    return NextResponse.json({ error: "unsupported chat session action" }, { status: 400 });
  }

  const reason = typeof body.reason === "string" && body.reason.trim()
    ? body.reason.trim()
    : "web_clear";

  try {
    const rows = await prisma.$queryRawUnsafe<ClearRow[]>(
      "SELECT clear_chat_session_context($1::uuid, $2::text) AS cleared",
      id,
      reason
    );
    const cleared = asRecord(normalizeJsonValue(rows[0]?.cleared));
    return NextResponse.json({
      ...cleared,
      session_id: typeof cleared.session_id === "string" ? cleared.session_id : id,
    });
  } catch (error: unknown) {
    console.error("Chat session clear API error:", error);
    return NextResponse.json({ error: errorMessage(error) }, { status: 500 });
  }
}
