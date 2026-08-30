import { errorMessage, jsonProxyResponse, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

/**
 * Exact ingestion job proxy. The Ingest page gets a job_id back when a source
 * is accepted, then polls this endpoint so the submitted job cannot disappear
 * from view just because it is outside the recent-list window.
 */

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> }
): Promise<Response> {
  const { id } = await params;
  const { search } = new URL(request.url);

  try {
    const upstream = await fetch(
      resolveHexisApiUrl(`/api/ingest/jobs/${encodeURIComponent(id)}`, search),
      { cache: "no-store" }
    );
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
