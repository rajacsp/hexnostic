export const DEFAULT_HEXIS_API_URL = "http://127.0.0.1:43817";

export function hexisApiBaseUrl(): string {
  return (
    process.env.HEXIS_API_URL ||
    process.env.HEXIS_API_BASE_URL ||
    DEFAULT_HEXIS_API_URL
  ).replace(/\/+$/, "");
}

export function resolveHexisApiUrl(pathname: string, search = ""): string {
  const normalizedPath = pathname.replace(/^\//, "");
  const url = new URL(normalizedPath, `${hexisApiBaseUrl()}/`);
  url.search = search;
  return url.toString();
}

export function hexisApiHeaders(init: HeadersInit = {}): Headers {
  const headers = new Headers(init);
  const apiKey = process.env.HEXIS_API_KEY?.trim();
  if (apiKey && !headers.has("authorization")) {
    headers.set("authorization", `Bearer ${apiKey}`);
  }
  return headers;
}

export function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

export function jsonProxyResponse(upstream: Response, body: string): Response {
  return new Response(body, {
    status: upstream.status,
    headers: {
      "Content-Type": upstream.headers.get("content-type") || "application/json",
    },
  });
}

export function sseError(message: string, status = 200): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(
        encoder.encode(`event: error\ndata: ${JSON.stringify({ message })}\n\n`)
      );
      controller.close();
    },
  });

  return new Response(stream, {
    status,
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    },
  });
}

export function sseProxyResponse(upstream: Response): Response {
  const headers = new Headers(upstream.headers);
  headers.set("Content-Type", "text/event-stream");
  headers.set("Cache-Control", "no-cache");
  headers.set("X-Accel-Buffering", "no");
  return new Response(upstream.body, {
    status: upstream.status,
    headers,
  });
}
