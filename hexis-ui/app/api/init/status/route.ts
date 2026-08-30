import { prisma } from "@/lib/prisma";
import { normalizeJsonValue } from "@/lib/db";

export const runtime = "nodejs";

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

export async function GET() {
  const statusRows =
    await prisma.$queryRaw<{ status: unknown }[]>`SELECT get_init_status() as status`;
  const modeRows =
    await prisma.$queryRaw<{ mode: unknown }[]>`SELECT get_config('agent.mode') as mode`;
  const profileRows =
    await prisma.$queryRaw<{ profile: unknown }[]>`SELECT get_config('agent.init_profile') as profile`;
  const consentRows =
    await prisma.$queryRaw<{ consent: string | null }[]>`SELECT get_agent_consent_status() as consent`;
  const configuredRows =
    await prisma.$queryRaw<{ configured: boolean | null }[]>`SELECT is_agent_configured() as configured`;
  const llmRows =
    await prisma.$queryRaw<{ llm: unknown }[]>`SELECT get_config('llm.heartbeat') as llm`;
  const llmSubRows =
    await prisma.$queryRaw<{ llm: unknown }[]>`SELECT get_config('llm.subconscious') as llm`;
  const heartbeatIntervalRows =
    await prisma.$queryRaw<{ value: unknown }[]>`SELECT get_config('heartbeat.heartbeat_interval_minutes') as value`;
  const heartbeatTokensRows =
    await prisma.$queryRaw<{ value: unknown }[]>`SELECT get_config('heartbeat.max_decision_tokens') as value`;
  const heartbeatRegenRows =
    await prisma.$queryRaw<{ value: unknown }[]>`SELECT get_config('heartbeat.base_regeneration') as value`;
  const heartbeatMaxEnergyRows =
    await prisma.$queryRaw<{ value: unknown }[]>`SELECT get_config('heartbeat.max_energy') as value`;
  const heartbeatAllowedRows =
    await prisma.$queryRaw<{ value: unknown }[]>`SELECT get_config('heartbeat.allowed_actions') as value`;
  const heartbeatCostRows =
    await prisma.$queryRaw<{ costs: unknown }[]>`
      SELECT jsonb_object_agg(
        regexp_replace(key, '^heartbeat\\.cost_', ''),
        value
      ) as costs
      FROM config
      WHERE key LIKE 'heartbeat.cost_%'
    `;
  const toolsRows =
    await prisma.$queryRaw<{ value: unknown }[]>`SELECT get_config('agent.tools') as value`;
  const llmConfig = asRecord(normalizeJsonValue(llmRows[0]?.llm));
  const llmSubConfig = asRecord(normalizeJsonValue(llmSubRows[0]?.llm));
  const consentRecords = {
    conscious: await fetchConsentRecord(llmConfig),
    subconscious: await fetchConsentRecord(llmSubConfig),
  };

  const status = normalizeJsonValue(statusRows[0]?.status) ?? {};
  const mode = normalizeJsonValue(modeRows[0]?.mode);
  const profile = normalizeJsonValue(profileRows[0]?.profile) ?? {};
  const consentStatus = consentRows[0]?.consent ?? null;
  const configured = Boolean(configuredRows[0]?.configured);
  const heartbeatSettings = {
    interval_minutes: normalizeJsonValue(heartbeatIntervalRows[0]?.value),
    decision_max_tokens: normalizeJsonValue(heartbeatTokensRows[0]?.value),
    base_regeneration: normalizeJsonValue(heartbeatRegenRows[0]?.value),
    max_energy: normalizeJsonValue(heartbeatMaxEnergyRows[0]?.value),
    allowed_actions: normalizeJsonValue(heartbeatAllowedRows[0]?.value) ?? [],
    action_costs: normalizeJsonValue(heartbeatCostRows[0]?.costs) ?? {},
    tools: normalizeJsonValue(toolsRows[0]?.value) ?? [],
  };

  return Response.json({
    status,
    mode,
    profile,
    consent_status: consentStatus,
    configured,
    llm_heartbeat: llmConfig ?? null,
    llm_subconscious: llmSubConfig ?? null,
    consent_records: consentRecords,
    heartbeat_settings: heartbeatSettings,
  });
}

async function fetchConsentRecord(llmConfig: Record<string, unknown> | null) {
  const provider = typeof llmConfig?.provider === "string" ? llmConfig.provider : null;
  const model = typeof llmConfig?.model === "string" ? llmConfig.model : null;
  const endpoint = typeof llmConfig?.endpoint === "string" ? llmConfig.endpoint : null;
  if (!provider && !model && !endpoint) {
    return null;
  }
  const rows = await prisma.$queryRaw<
    {
      decision: string;
      signature: string | null;
      provider: string | null;
      model: string | null;
      endpoint: string | null;
      decided_at: string;
      response: unknown;
    }[]
  >`SELECT decision, signature, provider, model, endpoint, decided_at, response
    FROM consent_log
    WHERE (${provider}::text IS NULL OR provider = ${provider}::text)
      AND (${model}::text IS NULL OR model = ${model}::text)
      AND (${endpoint}::text IS NULL OR endpoint = ${endpoint}::text)
    ORDER BY decided_at DESC
    LIMIT 1`;
  const row = rows[0];
  if (!row) return null;

  const stored = normalizeJsonValue(row.response) as Record<string, unknown> | null;
  let requestMessages = Array.isArray(stored?.request_messages)
    ? stored.request_messages
    : [];
  let rawContent = typeof stored?.raw_content === "string" ? stored.raw_content : "";
  let rawToolCalls = Array.isArray(stored?.raw_tool_calls) ? stored.raw_tool_calls : [];

  // Older consent rows predate inline exchange storage. Their paired usage
  // trace is still authoritative and lets a refreshed UI show the same detail.
  if (
    (row.decision === "decline" || row.decision === "abstain") &&
    requestMessages.length === 0 &&
    typeof stored?.request_id === "string"
  ) {
    const sessionKey = `init-consent:${stored.request_id}`;
    const traces = await prisma.$queryRaw<{ operation: string; metadata: unknown }[]>`
      SELECT operation, metadata
      FROM api_usage
      WHERE session_key = ${sessionKey}
        AND operation IN ('consent_request', 'consent_response')
      ORDER BY id
    `;
    for (const trace of traces) {
      const metadata = asRecord(normalizeJsonValue(trace.metadata));
      const request = asRecord(metadata?.request);
      if (trace.operation === "consent_request" && Array.isArray(request?.messages)) {
        requestMessages = request.messages;
      }
      if (trace.operation === "consent_response") {
        const response = asRecord(metadata?.response);
        if (typeof response?.content === "string") rawContent = response.content;
        if (Array.isArray(response?.tool_calls)) rawToolCalls = response.tool_calls;
      }
    }
  }

  const hasExchange = requestMessages.length > 0 || rawContent || rawToolCalls.length > 0;
  return {
    decision: row.decision,
    signature: row.signature,
    provider: row.provider,
    model: row.model,
    endpoint: row.endpoint,
    decided_at: row.decided_at,
    exchange: hasExchange
      ? {
          request_messages: requestMessages,
          raw_content: rawContent,
          raw_tool_calls: rawToolCalls,
        }
      : null,
  };
}
