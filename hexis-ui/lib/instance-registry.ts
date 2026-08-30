import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;

type InstanceRecord = {
  database?: unknown;
  host?: unknown;
  port?: unknown;
  user?: unknown;
  password_env?: unknown;
};

type RegistryFile = {
  current?: unknown;
  instances?: unknown;
};

export type DatabaseResolution = {
  url: string;
  source: "env:HEXIS_DATABASE_URL" | "registry:HEXIS_INSTANCE" | "registry:current" | "env:DATABASE_URL" | "postgres-env";
  instance: string | null;
};

function defaultRegistryPath(): string {
  return join(homedir(), ".hexis", "instances.json");
}

function readRegistry(registryPath: string): RegistryFile | null {
  if (!existsSync(registryPath)) return null;
  try {
    const parsed = JSON.parse(readFileSync(registryPath, "utf8"));
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as RegistryFile)
      : null;
  } catch {
    return null;
  }
}

function instanceFromRegistry(
  registry: RegistryFile | null,
  name: string | null | undefined
): InstanceRecord | null {
  if (!registry || !name) return null;
  const instances = registry.instances;
  if (!instances || typeof instances !== "object" || Array.isArray(instances)) return null;
  const item = (instances as Record<string, unknown>)[name];
  return item && typeof item === "object" && !Array.isArray(item)
    ? (item as InstanceRecord)
    : null;
}

function stringValue(value: unknown, fallback: string): string {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function portValue(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number.parseInt(value, 10);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

function dsnFromInstance(instance: InstanceRecord, env: Env): string {
  const database = stringValue(instance.database, "hexis_memory");
  const host = stringValue(instance.host, "localhost");
  const port = portValue(instance.port, 43815);
  const user = stringValue(instance.user, "hexis_user");
  const passwordEnv = stringValue(instance.password_env, "POSTGRES_PASSWORD");
  const password = env[passwordEnv] || "";
  return `postgresql://${user}:${password}@${host}:${port}/${database}`;
}

function dsnFromPostgresEnv(env: Env): string {
  const host = env.POSTGRES_HOST || "localhost";
  const port = env.POSTGRES_PORT || "43815";
  const database = env.POSTGRES_DB || "hexis_memory";
  const user = env.POSTGRES_USER || "hexis_user";
  const password = env.POSTGRES_PASSWORD || "hexis_password";
  return `postgresql://${user}:${password}@${host}:${port}/${database}`;
}

export function resolveHexisDatabase(
  env: Env = process.env,
  registryPath: string = defaultRegistryPath()
): DatabaseResolution {
  if (env.HEXIS_DATABASE_URL) {
    return { url: env.HEXIS_DATABASE_URL, source: "env:HEXIS_DATABASE_URL", instance: null };
  }

  const registry = readRegistry(registryPath);
  const envInstance = env.HEXIS_INSTANCE?.trim() || null;
  const fromEnv = instanceFromRegistry(registry, envInstance);
  if (fromEnv && envInstance) {
    return {
      url: dsnFromInstance(fromEnv, env),
      source: "registry:HEXIS_INSTANCE",
      instance: envInstance,
    };
  }

  const current = typeof registry?.current === "string" ? registry.current : null;
  const fromCurrent = instanceFromRegistry(registry, current);
  if (fromCurrent && current) {
    return {
      url: dsnFromInstance(fromCurrent, env),
      source: "registry:current",
      instance: current,
    };
  }

  if (env.DATABASE_URL) {
    return { url: env.DATABASE_URL, source: "env:DATABASE_URL", instance: null };
  }

  return { url: dsnFromPostgresEnv(env), source: "postgres-env", instance: null };
}

export function resolveHexisDatabaseUrl(
  env: Env = process.env,
  registryPath: string = defaultRegistryPath()
): string {
  return resolveHexisDatabase(env, registryPath).url;
}
