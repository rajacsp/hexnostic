import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { normalizeJsonValue } from "@/lib/db";

type Row = Record<string, unknown>;

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Failed to fetch documents";
}

export async function GET(req: NextRequest) {
  try {
    const url = new URL(req.url);
    const q = (url.searchParams.get("q") || "").trim();
    const mode = url.searchParams.get("mode") === "chunks" ? "chunks" : "documents";
    const type = url.searchParams.get("type") || "";
    const path = url.searchParams.get("path") || "";
    const limit = Math.min(parseInt(url.searchParams.get("limit") || "20", 10), 50);
    const offset = parseInt(url.searchParams.get("offset") || "0", 10);

    if (mode === "chunks" && q) {
      const chunks = await prisma.$queryRawUnsafe<Row[]>(
        `SELECT chunk_id, document_id, chunk_index, title, path, source_type,
                locator_kind, locator, heading_path, page_start, page_end,
                sheet_name, snippet, sensitivity, rank, rank_components
         FROM search_source_chunks($1, $2::int, NULL, NULLIF($3, ''), NULLIF($4, ''),
                                   NULL, NULL, NULL, NULL, NULL, NULL, false, $5::int)`,
        q, limit, path, type, offset
      );
      return NextResponse.json({
        mode,
        chunks: chunks.map((c) => ({
          ...c,
          rank: c.rank != null ? Number(c.rank) : null,
          locator: normalizeJsonValue(c.locator),
          rank_components: normalizeJsonValue(c.rank_components),
        })),
        limit,
        offset,
      });
    }

    let documents: Row[];
    let total = 0;
    if (q || type || path) {
      documents = await prisma.$queryRawUnsafe<Row[]>(
        `SELECT document_id, title, source_type, path, file_type, content_hash,
                word_count, size_bytes, created_at, updated_at, rank, snippet,
                rank_components, best_chunk_id, best_chunk_locator, extraction_warnings
         FROM search_source_documents(NULLIF($1, ''), $2::int, NULLIF($3, ''), NULLIF($4, ''),
                                      NULL, NULL, false, $5::int)`,
        q, limit, path, type, offset
      );
      total = documents.length + offset;
    } else {
      documents = await prisma.$queryRawUnsafe<Row[]>(
        `SELECT id AS document_id, title, source_type, path, file_type, content_hash,
                word_count, size_bytes, created_at, updated_at,
                0::float AS rank, left(content, 300) AS snippet,
                source_attribution->>'sensitivity' AS sensitivity,
                source_attribution->>'acquisition' AS acquisition
         FROM source_documents
         WHERE status = 'active'
         ORDER BY last_ingested_at DESC
         LIMIT $1 OFFSET $2`,
        limit, offset
      );
      const countRows = await prisma.$queryRawUnsafe<Row[]>(
        `SELECT count(*)::int AS total FROM source_documents WHERE status = 'active'`
      );
      total = Number(countRows[0]?.total || 0);
    }

    return NextResponse.json({
      mode,
      documents: documents.map((d) => ({
        ...d,
        rank: d.rank != null ? Number(d.rank) : null,
        word_count: d.word_count != null ? Number(d.word_count) : null,
        size_bytes: d.size_bytes != null ? Number(d.size_bytes) : null,
        rank_components: normalizeJsonValue(d.rank_components ?? null),
        best_chunk_locator: normalizeJsonValue(d.best_chunk_locator ?? null),
        extraction_warnings: normalizeJsonValue(d.extraction_warnings ?? null) || [],
      })),
      total,
      limit,
      offset,
    });
  } catch (error: unknown) {
    console.error("Documents API error:", error);
    return NextResponse.json({ error: errorMessage(error) }, { status: 500 });
  }
}
