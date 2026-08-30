import { NextResponse } from "next/server";

import { errorMessage, jsonProxyResponse, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));

  try {
    const res = await fetch(resolveHexisApiUrl("/api/init/consent/request"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body ?? {}),
      cache: "no-store",
    });

    const text = await res.text();
    return jsonProxyResponse(res, text);
  } catch (err: unknown) {
    console.error("Consent proxy failed:", err);
    return NextResponse.json(
      { error: errorMessage(err, "Consent request failed") },
      { status: 500 }
    );
  }
}
