import { afterEach, describe, expect, it, vi } from "vitest";

import { GET } from "./route";

describe("/api/ingest/jobs/[id]", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  it("proxies exact job polling to the Hexis API", async () => {
    const fetchMock = vi.fn(async () => new Response('{"id":"job-1"}', { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const response = await GET(
      new Request("http://localhost/api/ingest/jobs/job-1?trace=1"),
      { params: Promise.resolve({ id: "job-1" }) }
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: "job-1" });
    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:43817/api/ingest/jobs/job-1?trace=1",
      { cache: "no-store" }
    );
  });

  it("returns a recoverable 502 when the upstream API is unavailable", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("ECONNREFUSED");
      })
    );

    const response = await GET(
      new Request("http://localhost/api/ingest/jobs/job-1"),
      { params: Promise.resolve({ id: "job-1" }) }
    );
    const body = await response.json();

    expect(response.status).toBe(502);
    expect(body.error).toContain("Ingest upstream unreachable");
    expect(body.error).toContain("ECONNREFUSED");
  });
});
