import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { normalizeJsonValue } from "@/lib/db";

type MemoryRow = Record<string, unknown>;

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Failed to fetch memory";
}

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id } = await params;

    const rows = await prisma.$queryRawUnsafe<MemoryRow[]>(
      `SELECT id, type, content, importance, trust_level, access_count,
              decay_rate, status,
              COALESCE(source_attribution->>'source', metadata->>'source') AS source,
              metadata, created_at, last_accessed,
              calculate_strength(importance, decay_rate, created_at, last_reinforced)::float AS strength,
              CASE WHEN metadata->>'emotional_valence' ~ '^-?[0-9]+(\\.[0-9]+)?$'
                   THEN (metadata->>'emotional_valence')::float END AS emotional_valence
       FROM memories
       WHERE id = $1::uuid`,
      id
    );

    if (rows.length === 0) {
      return NextResponse.json({ error: "Memory not found" }, { status: 404 });
    }

    const m = rows[0];

    // Touch the memory to update access tracking
    await prisma.$queryRawUnsafe(`SELECT touch_memories(ARRAY[$1::uuid])`, id);

    // Provenance handles: the exact source documents/chunks behind this
    // memory (get_memory_story resolves ids, hashes, and references).
    let sourceDocuments: unknown = null;
    let sourceChunks: unknown = null;
    try {
      const storyRows = await prisma.$queryRawUnsafe<MemoryRow[]>(
        `SELECT get_memory_story($1::uuid) AS story`,
        id
      );
      const story = normalizeJsonValue(storyRows[0]?.story) as Record<string, unknown> | null;
      sourceDocuments = story?.source_documents ?? null;
      sourceChunks = story?.source_chunks ?? null;
    } catch (storyError) {
      console.error("Memory story lookup failed:", storyError);
    }

    return NextResponse.json({
      source_documents: sourceDocuments,
      source_chunks: sourceChunks,
      id: m.id,
      type: m.type,
      content: m.content,
      importance: m.importance != null ? Number(m.importance) : null,
      trust_level: m.trust_level != null ? Number(m.trust_level) : null,
      access_count: m.access_count != null ? Number(m.access_count) : null,
      decay_rate: m.decay_rate != null ? Number(m.decay_rate) : null,
      strength: m.strength != null ? Number(m.strength) : null,
      emotional_valence: m.emotional_valence != null ? Number(m.emotional_valence) : null,
      status: m.status,
      source: m.source,
      metadata: normalizeJsonValue(m.metadata),
      created_at: m.created_at,
      last_accessed: m.last_accessed,
    });
  } catch (error: unknown) {
    console.error("Memory detail API error:", error);
    return NextResponse.json(
      { error: errorMessage(error) },
      { status: 500 }
    );
  }
}
