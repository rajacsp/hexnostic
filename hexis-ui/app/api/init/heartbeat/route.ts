import { prisma } from "@/lib/prisma";
import { normalizeJsonValue, toJsonParam } from "@/lib/db";

export const runtime = "nodejs";

function parseIntParam(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return Math.trunc(parsed);
    }
  }
  return null;
}

function parseFloatParam(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return null;
}

function parseStringArray(value: unknown) {
  if (!Array.isArray(value)) {
    return null;
  }
  const cleaned = value
    .map((item) => (typeof item === "string" ? item.trim() : ""))
    .filter(Boolean);
  return cleaned;
}

function parseRecord(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));
  const intervalMinutes = parseIntParam(body?.interval_minutes);
  const decisionMaxTokens = parseIntParam(body?.decision_max_tokens);
  const baseRegeneration = parseFloatParam(body?.base_regeneration);
  const maxEnergy = parseFloatParam(body?.max_energy);
  const allowedActions = parseStringArray(body?.allowed_actions);
  const actionCosts = parseRecord(body?.action_costs);
  const tools = parseStringArray(body?.tools);

  const rows = await prisma.$queryRaw<{ result: unknown }[]>`
    SELECT init_heartbeat_settings(
      ${intervalMinutes}::int,
      ${decisionMaxTokens}::int,
      ${baseRegeneration}::float,
      ${maxEnergy}::float,
      ${toJsonParam(allowedActions)}::jsonb,
      ${toJsonParam(actionCosts)}::jsonb,
      ${toJsonParam(tools)}::jsonb
    ) as result
  `;
  const statusRows =
    await prisma.$queryRaw<{ status: unknown }[]>`SELECT get_init_status() as status`;

  return Response.json({
    result: normalizeJsonValue(rows[0]?.result),
    status: normalizeJsonValue(statusRows[0]?.status),
  });
}
