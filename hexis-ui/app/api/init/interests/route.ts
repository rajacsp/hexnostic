import { prisma } from "@/lib/prisma";
import { normalizeJsonValue, toJsonParam } from "@/lib/db";
import { initRouteError } from "@/lib/init-errors";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));
  const interests = body.interests ?? null;

  try {
    const rows = await prisma.$queryRaw<{ result: unknown }[]>`
      SELECT init_interests(${toJsonParam(interests)}::jsonb) as result
    `;
    const statusRows =
      await prisma.$queryRaw<{ status: unknown }[]>`SELECT get_init_status() as status`;

    return Response.json({
      result: normalizeJsonValue(rows[0]?.result),
      status: normalizeJsonValue(statusRows[0]?.status),
    });
  } catch (error) {
    return initRouteError(error, "Failed to save interests.");
  }
}
