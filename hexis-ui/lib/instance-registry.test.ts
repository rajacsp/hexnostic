import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { resolveHexisDatabase } from "./instance-registry";

function registryFile(data: unknown): string {
  const dir = mkdtempSync(join(tmpdir(), "hexis-ui-registry-"));
  const path = join(dir, "instances.json");
  writeFileSync(path, JSON.stringify(data));
  return path;
}

describe("resolveHexisDatabase", () => {
  it("honors explicit UI database URL first", () => {
    const path = registryFile({ current: "live", instances: {} });

    expect(
      resolveHexisDatabase(
        {
          HEXIS_DATABASE_URL: "postgresql://explicit/db",
          DATABASE_URL: "postgresql://stale/db",
        },
        path
      )
    ).toMatchObject({
      url: "postgresql://explicit/db",
      source: "env:HEXIS_DATABASE_URL",
    });
  });

  it("uses HEXIS_INSTANCE from the same registry Python uses", () => {
    const path = registryFile({
      current: "old",
      instances: {
        old: { database: "hexis_old" },
        live: {
          database: "hexis_live",
          host: "db.local",
          port: 15432,
          user: "agent",
          password_env: "LIVE_PASSWORD",
        },
      },
    });

    expect(
      resolveHexisDatabase(
        {
          HEXIS_INSTANCE: "live",
          LIVE_PASSWORD: "secret",
          DATABASE_URL: "postgresql://stale/db",
        },
        path
      )
    ).toMatchObject({
      url: "postgresql://agent:secret@db.local:15432/hexis_live",
      source: "registry:HEXIS_INSTANCE",
      instance: "live",
    });
  });

  it("uses the current registry instance before a stale DATABASE_URL", () => {
    const path = registryFile({
      current: "current",
      instances: {
        current: {
          database: "hexis_current",
          password_env: "POSTGRES_PASSWORD",
        },
      },
    });

    expect(
      resolveHexisDatabase(
        {
          POSTGRES_PASSWORD: "pw",
          DATABASE_URL: "postgresql://stale/db",
        },
        path
      )
    ).toMatchObject({
      url: "postgresql://hexis_user:pw@localhost:43815/hexis_current",
      source: "registry:current",
      instance: "current",
    });
  });

  it("falls back to POSTGRES_* defaults when no registry or URL exists", () => {
    expect(resolveHexisDatabase({}, join(tmpdir(), "missing-hexis-registry.json"))).toMatchObject({
      url: "postgresql://hexis_user:hexis_password@localhost:43815/hexis_memory",
      source: "postgres-env",
    });
  });
});
