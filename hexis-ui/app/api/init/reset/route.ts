import { prisma } from "@/lib/prisma";
import { normalizeJsonValue } from "@/lib/db";

export const runtime = "nodejs";

// Destructive: reset_initialization() wipes the entire init. Callers MUST pass an
// explicit confirmation in the request body ({ confirm: true } or { confirm: "reset" });
// without it we return 400 and do NOT touch the database.
export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));
  const confirmed = body?.confirm === true || body?.confirm === "reset";
  if (!confirmed) {
    return Response.json(
      { error: "reset requires explicit confirmation" },
      { status: 400 }
    );
  }

  const rows =
    await prisma.$queryRaw<{ result: unknown }[]>`SELECT reset_initialization() as result`;

  return Response.json({
    result: normalizeJsonValue(rows[0]?.result),
  });
}
