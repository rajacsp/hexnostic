import { errorMessage, jsonProxyResponse, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

/**
 * URL ingestion proxy: forwards to the Python `hexis-api` server
 * (`POST /api/ingest/url`), which enqueues a durable fetch+ingest job.
 */

export async function POST(request: Request): Promise<Response> {
  let bodyText = "";
  try {
    bodyText = await request.text();
  } catch (err: unknown) {
    const message = errorMessage(err, "Failed to read request body.");
    return Response.json({ error: message || "Failed to read request body." }, { status: 400 });
  }

  try {
    const upstream = await fetch(resolveHexisApiUrl("/api/ingest/url"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: bodyText,
    });
    const payload = await upstream.text();
    return jsonProxyResponse(upstream, payload);
  } catch (err: unknown) {
    const message = errorMessage(err, "Unknown error");
    return Response.json(
      { error: `Ingest upstream unreachable: ${message}` },
      { status: 502 }
    );
  }
}
