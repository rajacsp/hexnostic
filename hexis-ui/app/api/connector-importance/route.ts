import { errorMessage, hexisApiHeaders, jsonProxyResponse, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

export async function GET(request: Request): Promise<Response> {
  const search = new URL(request.url).search;
  try {
    const upstream = await fetch(resolveHexisApiUrl("/api/connector-importance", search), {
      headers: hexisApiHeaders(),
      cache: "no-store",
    });
    const payload = await upstream.text();
    return jsonProxyResponse(upstream, payload);
  } catch (error: unknown) {
    return Response.json(
      { error: `Importance upstream unreachable: ${errorMessage(error, "Unknown error")}` },
      { status: 502 }
    );
  }
}
