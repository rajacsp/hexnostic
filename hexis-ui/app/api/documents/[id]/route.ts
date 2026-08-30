import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { normalizeJsonValue } from "@/lib/db";

type Row = Record<string, unknown>;

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Failed to open document";
}

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id } = await params;
    const url = new URL(req.url);
    const offset = parseInt(url.searchParams.get("offset") || "0", 10);
    const chars = Math.min(parseInt(url.searchParams.get("chars") || "6000", 10), 40000);
    const pageStart = url.searchParams.get("page_start");
    const pageEnd = url.searchParams.get("page_end");

    if (pageStart) {
      const rows = await prisma.$queryRawUnsafe<Row[]>(
        `SELECT open_source_chunks(NULL, $1::uuid, NULL, NULL, $2::int, $3::int) AS payload`,
        id, parseInt(pageStart, 10), parseInt(pageEnd || pageStart, 10)
      );
      return NextResponse.json(normalizeJsonValue(rows[0]?.payload));
    }

    const rows = await prisma.$queryRawUnsafe<Row[]>(
      `SELECT open_source_document($1::uuid, NULL, NULL, $2::int, $3::int) AS payload`,
      id, offset, chars
    );
    const doc = normalizeJsonValue(rows[0]?.payload) as Record<string, unknown>;
    if (!doc || doc.error) {
      return NextResponse.json({ error: doc?.error || "not_found" }, { status: 404 });
    }

    // Chunk locators: the navigation surface (page picker / sheet select).
    const chunks = await prisma.$queryRawUnsafe<Row[]>(
      `SELECT id AS chunk_id, chunk_index, locator_kind, heading_path,
              page_start, page_end, sheet_name, embedding_status
       FROM source_document_chunks
       WHERE source_document_id = $1::uuid
       ORDER BY chunk_index
       LIMIT 200`,
      id
    );

    // Memories distilled from this source (provenance links).
    const memories = await prisma.$queryRawUnsafe<Row[]>(
      `SELECT id, type, left(content, 200) AS content, importance, created_at
       FROM memories
       WHERE status = 'active'
         AND (source_attribution->>'source_document_id' = $1
              OR source_attribution->>'document_id' = $1)
       ORDER BY created_at DESC
       LIMIT 25`,
      id
    );

    return NextResponse.json({
      document: doc,
      chunks: chunks.map((c) => ({
        ...c,
        chunk_index: Number(c.chunk_index),
      })),
      memories: memories.map((m) => ({
        ...m,
        importance: m.importance != null ? Number(m.importance) : null,
      })),
    });
  } catch (error: unknown) {
    console.error("Document detail API error:", error);
    return NextResponse.json({ error: errorMessage(error) }, { status: 500 });
  }
}
