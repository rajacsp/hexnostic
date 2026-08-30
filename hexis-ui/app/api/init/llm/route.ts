import { prisma } from "@/lib/prisma";
import { normalizeJsonValue, toJsonParam } from "@/lib/db";
import { resolveInitLlmEndpoint } from "@/lib/init-llm";
import { readFile, writeFile } from "fs/promises";
import path from "path";

export const runtime = "nodejs";

type LlmInput = {
  provider?: string;
  model?: string;
  endpoint?: string;
  api_key?: string;
};

type LlmConfig = {
  provider: string;
  model: string;
  endpoint?: string;
  api_key_env?: string;
};

const API_KEY_REQUIRED = new Set(["openai", "anthropic", "grok", "gemini"]);
function normalizeText(value: unknown) {
  if (typeof value !== "string") {
    return "";
  }
  return value.trim();
}

function normalizeProvider(value: unknown) {
  return normalizeText(value).toLowerCase();
}

function formatEnvValue(value: string) {
  if (!value) {
    return "";
  }
  if (/[\s#"'\n]/.test(value)) {
    return `"${value.replace(/"/g, '\\"')}"`;
  }
  return value;
}

async function upsertEnvVar(filePath: string, key: string, value: string) {
  let content = "";
  try {
    content = await readFile(filePath, "utf-8");
  } catch {
    content = "";
  }
  const formatted = `${key}=${formatEnvValue(value)}`;
  const lines = content.split(/\r?\n/);
  let replaced = false;
  const next = lines.map((line) => {
    if (line.startsWith(`${key}=`)) {
      replaced = true;
      return formatted;
    }
    return line;
  });
  if (!replaced) {
    next.push(formatted);
  }
  const trimmed = next.filter((line, idx, arr) => idx < arr.length - 1 || line.trim() !== "");
  const output = `${trimmed.join("\n")}\n`;
  await writeFile(filePath, output, "utf-8");
}

function buildLlmConfig(input: LlmInput, apiKeyEnv?: string): LlmConfig {
  const provider = normalizeProvider(input.provider);
  const model = normalizeText(input.model);
  const endpoint = normalizeText(input.endpoint);
  const config: LlmConfig = { provider, model };
  if (endpoint) {
    config.endpoint = endpoint;
  }
  if (apiKeyEnv) {
    config.api_key_env = apiKeyEnv;
  }
  return config;
}

export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));
  const consciousInput = (body?.conscious ?? {}) as LlmInput;
  const subconsciousInput = (body?.subconscious ?? {}) as LlmInput;

  const consciousProvider = normalizeProvider(consciousInput.provider);
  const subconsciousProvider = normalizeProvider(subconsciousInput.provider);
  const consciousModel = normalizeText(consciousInput.model);
  const subconsciousModel = normalizeText(subconsciousInput.model);
  const consciousEndpoint = normalizeText(consciousInput.endpoint);
  const subconsciousEndpoint = normalizeText(subconsciousInput.endpoint);
  const consciousKey = normalizeText(consciousInput.api_key);
  const subconsciousKey = normalizeText(subconsciousInput.api_key);

  const missing: string[] = [];
  if (!consciousProvider) missing.push("conscious provider");
  if (!consciousModel) missing.push("conscious model");
  if (consciousProvider === "openai_compatible" && !consciousEndpoint) {
    missing.push("conscious endpoint");
  }
  if (!subconsciousProvider) missing.push("subconscious provider");
  if (!subconsciousModel) missing.push("subconscious model");
  if (subconsciousProvider === "openai_compatible" && !subconsciousEndpoint) {
    missing.push("subconscious endpoint");
  }

  if (API_KEY_REQUIRED.has(consciousProvider) && !consciousKey) {
    missing.push("conscious API key");
  }
  if (API_KEY_REQUIRED.has(subconsciousProvider) && !subconsciousKey) {
    missing.push("subconscious API key");
  }

  if (missing.length > 0) {
    return Response.json({ error: `Missing ${missing.join(", ")}` }, { status: 400 });
  }

  const uiRoot = process.cwd();
  const repoRoot = path.resolve(uiRoot, "..");
  const envTargets = [path.join(uiRoot, ".env.local"), path.join(repoRoot, ".env")];

  const consciousEnv = "HEXIS_LLM_CONSCIOUS_API_KEY";
  const subconsciousEnv = "HEXIS_LLM_SUBCONSCIOUS_API_KEY";

  if (consciousKey) {
    for (const envPath of envTargets) {
      await upsertEnvVar(envPath, consciousEnv, consciousKey);
    }
    process.env[consciousEnv] = consciousKey;
  }
  if (subconsciousKey) {
    for (const envPath of envTargets) {
      await upsertEnvVar(envPath, subconsciousEnv, subconsciousKey);
    }
    process.env[subconsciousEnv] = subconsciousKey;
  }

  const normalizedConsciousEndpoint = resolveInitLlmEndpoint(
    consciousProvider,
    consciousEndpoint
  );
  const normalizedSubconsciousEndpoint = resolveInitLlmEndpoint(
    subconsciousProvider,
    subconsciousEndpoint
  );

  const heartbeatConfig = buildLlmConfig(
    { ...consciousInput, endpoint: normalizedConsciousEndpoint },
    consciousKey ? consciousEnv : undefined
  );
  const subconsciousConfig = buildLlmConfig(
    { ...subconsciousInput, endpoint: normalizedSubconsciousEndpoint },
    subconsciousKey ? subconsciousEnv : undefined
  );

  const statusRows = await prisma.$queryRaw<{ status: unknown }[]>`
    SELECT init_llm_config(
      ${toJsonParam(heartbeatConfig)}::jsonb,
      ${toJsonParam(subconsciousConfig)}::jsonb
    ) as status
  `;

  return Response.json({
    status: normalizeJsonValue(statusRows[0]?.status),
  });
}
