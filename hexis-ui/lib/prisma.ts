import { PrismaClient } from "@prisma/client";

import { resolveHexisDatabaseUrl } from "./instance-registry";

const globalForPrisma = globalThis as unknown as {
  prisma?: PrismaClient;
  prismaDatabaseUrl?: string;
};
const databaseUrl = resolveHexisDatabaseUrl();

export const prisma =
  globalForPrisma.prisma && globalForPrisma.prismaDatabaseUrl === databaseUrl
    ? globalForPrisma.prisma
    : new PrismaClient({
        datasources: databaseUrl ? { db: { url: databaseUrl } } : undefined,
        log: ["error"],
      });

if (process.env.NODE_ENV !== "production") {
  globalForPrisma.prisma = prisma;
  globalForPrisma.prismaDatabaseUrl = databaseUrl;
}
