import { prisma } from "@/lib/prisma";
import { normalizeJsonValue, toJsonParam } from "@/lib/db";
import { initRouteError } from "@/lib/init-errors";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));
  const card = body.card ?? {};
  const userName = typeof body.user_name === "string" ? body.user_name : "User";
  const characterFilename =
    typeof body.character_filename === "string" ? body.character_filename : null;
  const portrait = typeof body.portrait === "string" ? body.portrait : null;

  try {
    const rows = await prisma.$queryRaw<{ result: unknown }[]>`
      SELECT init_from_character_card(${toJsonParam(card)}::jsonb, ${userName}) as result
    `;
    if (characterFilename || portrait) {
      await prisma.$queryRaw`
        SELECT merge_init_profile(jsonb_build_object(
          'agent', jsonb_strip_nulls(jsonb_build_object(
            'character_filename', ${characterFilename},
            'portrait', ${portrait}
          ))
        ))
      `;
    }
    const statusRows = await prisma.$queryRaw<
      { status: unknown }[]
    >`SELECT get_init_status() as status`;

    return Response.json({
      result: normalizeJsonValue(rows[0]?.result),
      status: normalizeJsonValue(statusRows[0]?.status),
    });
  } catch (error) {
    return initRouteError(error, "Failed to apply character card.");
  }
}
