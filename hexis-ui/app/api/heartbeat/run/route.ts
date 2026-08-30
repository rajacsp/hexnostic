import { errorMessage, hexisApiHeaders, resolveHexisApiUrl, sseProxyResponse } from "@/lib/python-api";

export const runtime = "nodejs";

export async function POST(): Promise<Response> {
  try {
    const upstream = await fetch(resolveHexisApiUrl("/api/heartbeat/run"), {
      method: "POST",
      headers: hexisApiHeaders({ accept: "text/event-stream" }),
      cache: "no-store",
    });
    return sseProxyResponse(upstream);
  } catch (error: unknown) {
    const message = errorMessage(error, "Unable to reach the Hexis API.");
    return Response.json({ error: message }, { status: 502 });
  }
}
