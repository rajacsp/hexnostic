import { NextResponse } from "next/server";

import { errorMessage, hexisApiHeaders, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

type RouteContext = { params: Promise<{ path: string[] }> };

function upstreamUrl(path: string[], requestUrl: string): string {
  return resolveHexisApiUrl(
    `/api/init/auth/${path.map(encodeURIComponent).join("/")}`,
    new URL(requestUrl).search
  );
}

async function proxy(request: Request, context: RouteContext): Promise<Response> {
  const { path } = await context.params;
  const headers = hexisApiHeaders({ accept: "application/json" });

  let body: string | undefined;
  if (request.method !== "GET" && request.method !== "HEAD") {
    headers.set("content-type", request.headers.get("content-type") || "application/json");
    body = await request.text();
  }

  const url = upstreamUrl(path, request.url);
  try {
    const upstream = await fetch(url, {
      method: request.method,
      headers,
      body,
      cache: "no-store",
      signal: request.signal,
    });
    return new NextResponse(await upstream.text(), {
      status: upstream.status,
      headers: {
        "content-type": upstream.headers.get("content-type") || "application/json",
        "cache-control": "no-store",
      },
    });
  } catch (error: unknown) {
    const reason = errorMessage(error, "Make sure the Hexis stack is running.");
    return NextResponse.json(
      {
        detail:
          `Unable to reach the Hexis API at ${url}. ` +
          `${reason || "Make sure the Hexis stack is running."}`,
      },
      { status: 503 }
    );
  }
}

export async function GET(request: Request, context: RouteContext) {
  return proxy(request, context);
}

export async function POST(request: Request, context: RouteContext) {
  return proxy(request, context);
}
