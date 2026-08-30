import { prisma } from "@/lib/prisma";
import { normalizeJsonValue } from "@/lib/db";

export const runtime = "nodejs";

// One timezone step for every init frontend (#79): the wizard sends the
// browser's IANA zone; validation, idempotency, and the never-overwrite-an-
// explicit-choice rule live in the DB (init_set_timezone).
export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));
  const timezone = typeof body.timezone === "string" ? body.timezone : null;

  const rows =
    await prisma.$queryRaw<{ applied: boolean | null }[]>`SELECT init_set_timezone(${timezone}) as applied`;

  return Response.json({ applied: normalizeJsonValue(rows[0]?.applied) === true });
}
