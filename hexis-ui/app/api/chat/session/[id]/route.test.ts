import { afterEach, describe, expect, it, vi } from "vitest";

import { GET, POST } from "./route";
import { prisma } from "@/lib/prisma";

vi.mock("@/lib/prisma", () => ({
  prisma: {
    $queryRawUnsafe: vi.fn(),
  },
}));

const query = vi.mocked(prisma.$queryRawUnsafe);

describe("/api/chat/session/[id]", () => {
  afterEach(() => {
    query.mockReset();
  });

  it("hydrates a DB-owned chat session", async () => {
    query.mockResolvedValueOnce([
      {
        session: {
          session_id: "11111111-1111-4111-8111-111111111111",
          messages: [
            { role: "user", content: "hello" },
            { role: "assistant", content: "hi" },
          ],
        },
      },
    ]);

    const response = await GET(new Request("http://localhost/api/chat/session/x"), {
      params: Promise.resolve({ id: "11111111-1111-4111-8111-111111111111" }),
    });
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.messages).toEqual([
      { role: "user", content: "hello" },
      { role: "assistant", content: "hi" },
    ]);
    expect(query).toHaveBeenCalledWith(
      "SELECT hydrate_chat_session($1::uuid) AS session",
      "11111111-1111-4111-8111-111111111111"
    );
  });

  it("rejects non-UUID session ids", async () => {
    const response = await GET(new Request("http://localhost/api/chat/session/not-a-uuid"), {
      params: Promise.resolve({ id: "not-a-uuid" }),
    });

    expect(response.status).toBe(422);
    expect(query).not.toHaveBeenCalled();
  });

  it("clears visible context while preserving long-term memory", async () => {
    query.mockResolvedValueOnce([
      {
        cleared: {
          session_id: "11111111-1111-4111-8111-111111111111",
          cleared_messages: 2,
          long_term_memory_preserved: true,
        },
      },
    ]);

    const response = await POST(
      new Request("http://localhost/api/chat/session/11111111-1111-4111-8111-111111111111", {
        method: "POST",
        body: JSON.stringify({ action: "clear_context", reason: "test_clear" }),
      }),
      { params: Promise.resolve({ id: "11111111-1111-4111-8111-111111111111" }) }
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toMatchObject({
      session_id: "11111111-1111-4111-8111-111111111111",
      cleared_messages: 2,
      long_term_memory_preserved: true,
    });
    expect(query).toHaveBeenCalledWith(
      "SELECT clear_chat_session_context($1::uuid, $2::text) AS cleared",
      "11111111-1111-4111-8111-111111111111",
      "test_clear"
    );
  });

  it("rejects unsupported session actions", async () => {
    const response = await POST(
      new Request("http://localhost/api/chat/session/11111111-1111-4111-8111-111111111111", {
        method: "POST",
        body: JSON.stringify({ action: "archive" }),
      }),
      { params: Promise.resolve({ id: "11111111-1111-4111-8111-111111111111" }) }
    );

    expect(response.status).toBe(400);
    expect(query).not.toHaveBeenCalled();
  });
});
