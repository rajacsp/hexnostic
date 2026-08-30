import { errorMessage, jsonProxyResponse, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

/**
 * File-upload ingestion proxy. Dropped/picked files in the chat composer and
 * the Ingest page land here as multipart form data and are forwarded to the
 * Python `hexis-api` server (`POST /api/ingest/file`), which preserves the
 * original bytes as a source artifact and enqueues a durable ingestion job.
 */

export async function POST(request: Request): Promise<Response> {
  let form: FormData;
  try {
    form = await request.formData();
  } catch (err: unknown) {
    const message = errorMessage(err, "Failed to read upload.");
    return Response.json({ error: message || "Failed to read upload." }, { status: 400 });
  }

  try {
    const upstream = await fetch(resolveHexisApiUrl("/api/ingest/file"), {
      method: "POST",
      body: form,
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
