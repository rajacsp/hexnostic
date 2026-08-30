import {
  downloadCharacterCatalogItem,
  parseCharacterCatalogProvider,
  searchCharacterCatalog,
} from "@/lib/character-catalog";

export const runtime = "nodejs";
export const maxDuration = 60;

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const provider = parseCharacterCatalogProvider(searchParams.get("provider"));
  if (!provider) {
    return Response.json({ error: "Unknown character catalog provider." }, { status: 400 });
  }

  const query = searchParams.get("query") ?? "";
  const tags = (searchParams.get("tags") ?? "")
    .split(",")
    .map((tag) => tag.trim())
    .filter(Boolean);
  const page = Math.max(1, Number(searchParams.get("page") ?? "1") || 1);
  const includeNsfw = searchParams.get("include_nsfw") === "true";
  const sort = searchParams.get("sort") ?? "";

  try {
    const result = await searchCharacterCatalog({
      provider,
      query,
      tags,
      page,
      includeNsfw,
      sort,
    });
    return Response.json(result);
  } catch (error) {
    return Response.json(
      {
        provider,
        query,
        page,
        total: 0,
        totalPages: null,
        items: [],
        status: "degraded",
        message:
          error instanceof Error && error.message
            ? error.message
            : "Unable to search this character catalog.",
      },
      { status: 200 }
    );
  }
}

export async function POST(request: Request) {
  const body = await request.json().catch(() => null);
  const provider = parseCharacterCatalogProvider(
    typeof body?.provider === "string" ? body.provider : null
  );
  if (!body || !provider) {
    return Response.json({ error: "Missing character catalog provider." }, { status: 400 });
  }
  const id = typeof body.id === "string" ? body.id : "";
  if (!id.trim()) {
    return Response.json({ error: "Missing character id." }, { status: 400 });
  }

  try {
    const result = await downloadCharacterCatalogItem({
      provider,
      id,
      path: typeof body.path === "string" ? body.path : null,
      avatarUrl: typeof body.avatarUrl === "string" ? body.avatarUrl : null,
      pageUrl: typeof body.pageUrl === "string" ? body.pageUrl : null,
    });
    return Response.json(result);
  } catch (error) {
    return Response.json(
      {
        error:
          error instanceof Error && error.message
            ? error.message
            : "Unable to download this character.",
      },
      { status: 502 }
    );
  }
}
