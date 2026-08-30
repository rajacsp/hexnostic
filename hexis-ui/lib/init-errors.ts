export function initRouteError(error: unknown, fallback: string): Response {
  const detail = error instanceof Error ? error.message : String(error);
  if (isEmbeddingBatchLimit(detail)) {
    return Response.json(
      {
        error:
          "The embedding request exceeded the local service batch limit. Run `hexis migrate`, then retry this step.",
        detail,
      },
      { status: 500 }
    );
  }
  if (isEmbeddingUnavailable(detail)) {
    return Response.json(
      {
        error:
          "The embedding service is not reachable. Start it with `embeddinggemma`, or run `hexis up`, then retry this step.",
        detail,
      },
      { status: 503 }
    );
  }
  return Response.json(
    {
      error: fallback,
      detail,
    },
    { status: 500 }
  );
}

export function isEmbeddingBatchLimit(message: string): boolean {
  return /batch size \d+ exceeds maximum \d+/i.test(message);
}

export function isEmbeddingUnavailable(message: string): boolean {
  if (isEmbeddingBatchLimit(message)) return false;
  return /Embedding service not available|Failed to get embeddings|host\.docker\.internal.*(?:42666|11434)|port (?:42666|11434)|ECONNREFUSED/i.test(
    message
  );
}
