import { NextResponse } from "next/server";

import { errorMessage, jsonProxyResponse, resolveHexisApiUrl } from "@/lib/python-api";

export const runtime = "nodejs";

// Owner override: activate the agent even though the model didn't consent.
// Consent is a signal, not a lock — it's the owner's AI.
export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));

  try {
    const res = await fetch(resolveHexisApiUrl("/api/init/consent/override"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body ?? {}),
      cache: "no-store",
    });

    const text = await res.text();
    return jsonProxyResponse(res, text);
  } catch (err: unknown) {
    console.error("Consent override proxy failed:", err);
    return NextResponse.json(
      { error: errorMessage(err, "Consent override failed") },
      { status: 500 }
    );
  }
}
