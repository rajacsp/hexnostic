import { errorMessage, hexisApiHeaders, jsonProxyResponse, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

export async function POST(
  request: Request,
  context: { params: Promise<{ id: string }> }
): Promise<Response> {
  const { id } = await context.params;
  let bodyText = "";
  try {
    bodyText = await request.text();
  } catch (error: unknown) {
    return Response.json(
      { error: errorMessage(error, "Failed to read request body.") },
      { status: 400 }
    );
  }

  try {
    const upstream = await fetch(
      resolveHexisApiUrl(`/api/user-model/claims/${encodeURIComponent(id)}/review`),
      {
        method: "POST",
        headers: hexisApiHeaders({ "Content-Type": "application/json" }),
        body: bodyText,
      }
    );
    const payload = await upstream.text();
    return jsonProxyResponse(upstream, payload);
  } catch (error: unknown) {
    return Response.json(
      { error: `User model upstream unreachable: ${errorMessage(error, "Unknown error")}` },
      { status: 502 }
    );
  }
}
