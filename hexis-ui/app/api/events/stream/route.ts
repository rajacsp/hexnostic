import { errorMessage, resolveHexisApiUrl, sseError, sseProxyResponse } from "@/lib/python-api";

export const runtime = "nodejs";

/**
 * SSE proxy to the Python FastAPI gateway events stream.
 *
 * The browser connects to same-origin `/api/events/stream` and receives
 * real-time gateway events (heartbeat, maintenance, webhook, etc.) via SSE.
 * Used by the dashboard and sidebar to trigger instant status refreshes
 * instead of 30-second polling.
 */

export async function GET(): Promise<Response> {
  const url = resolveHexisApiUrl("/api/events/stream");

  let upstream: Response;
  try {
    upstream = await fetch(url, {
      headers: { Accept: "text/event-stream" },
    });
  } catch (err: unknown) {
    return sseError(`Failed to reach Hexis API at ${url}: ${errorMessage(err, "Unknown error")}`);
  }

  return sseProxyResponse(upstream);
}
