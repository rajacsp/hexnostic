import { NextResponse } from "next/server";

import {
  errorMessage,
  hexisApiHeaders,
  jsonProxyResponse,
  resolveHexisApiUrl,
} from "@/lib/python-api";

export const runtime = "nodejs";

export async function POST(request: Request): Promise<Response> {
  let bodyText = "";
  try {
    bodyText = await request.text();
  } catch (error: unknown) {
    return NextResponse.json(
      { error: errorMessage(error, "Failed to read integration action body.") },
      { status: 400 }
    );
  }

  try {
    const upstream = await fetch(resolveHexisApiUrl("/api/integrations/action"), {
      method: "POST",
      headers: hexisApiHeaders({ "Content-Type": "application/json" }),
      body: bodyText,
    });
    const payload = await upstream.text();
    return jsonProxyResponse(upstream, payload);
  } catch (error: unknown) {
    console.error("Integration action API error:", error);
    return NextResponse.json(
      {
        error: `Integration upstream unreachable: ${errorMessage(
          error,
          "Failed to reach Hexis API"
        )}`,
      },
      { status: 502 }
    );
  }
}
