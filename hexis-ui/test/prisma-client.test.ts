import { describe, expect, it } from "vitest";

describe("prisma client", () => {
  it("is generated and importable", async () => {
    try {
      const mod = await import("../lib/prisma");
      expect(mod.prisma).toBeDefined();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      throw new Error(
        `Prisma client missing. Run \"bunx prisma generate\" in hexis-ui. Original error: ${message}`
      );
    }
  });
});
