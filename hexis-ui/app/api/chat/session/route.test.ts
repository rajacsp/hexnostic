import { afterEach, describe, expect, it, vi } from "vitest";

import { POST } from "./route";
import { prisma } from "@/lib/prisma";

vi.mock("@/lib/prisma", () => ({
  prisma: {
    $queryRawUnsafe: vi.fn(),
  },
}));

const query = vi.mocked(prisma.$queryRawUnsafe);

describe("/api/chat/session", () => {
  afterEach(() => {
    query.mockReset();
  });

  it("creates a web-owned chat session in the database", async () => {
    query.mockResolvedValueOnce([
      {
        session: {
          session_id: "11111111-1111-4111-8111-111111111111",
          surface: "web",
          status: "active",
        },
      },
    ]);

    const response = await POST();
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toMatchObject({
      session_id: "11111111-1111-4111-8111-111111111111",
      surface: "web",
      status: "active",
    });
    expect(query).toHaveBeenCalledWith(
      "SELECT get_or_create_chat_session(NULL::uuid, $1::text, NULL::text, $2::jsonb) AS session",
      "web",
      expect.any(String)
    );
    expect(JSON.parse(query.mock.calls[0][2] as string)).toMatchObject({
      source: "web",
      created_by: "user",
    });
  });

  it("fails loudly when the database does not return a session id", async () => {
    query.mockResolvedValueOnce([{ session: { surface: "web" } }]);

    const response = await POST();
    const body = await response.json();

    expect(response.status).toBe(500);
    expect(body.error).toBe("database did not return a session id");
  });
});
