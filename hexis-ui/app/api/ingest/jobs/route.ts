import { errorMessage, jsonProxyResponse, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

/**
 * Ingestion job listing proxy: the Ingest page polls this for live receipts —
 * what ran, what's pending, what failed and why.
 */

export async function GET(request: Request): Promise<Response> {
  const { search } = new URL(request.url);
  try {
    const upstream = await fetch(resolveHexisApiUrl("/api/ingest/jobs", search), {
      cache: "no-store",
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
