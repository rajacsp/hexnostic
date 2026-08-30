import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { normalizeJsonValue } from "@/lib/db";

type MemoryRow = Record<string, unknown>;
type HealthRow = Record<string, unknown>;

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Failed to fetch memories";
}

export async function GET(req: NextRequest) {
  try {
    const url = new URL(req.url);
    const q = url.searchParams.get("q") || "";
    const type = url.searchParams.get("type") || "";
    const limit = Math.min(parseInt(url.searchParams.get("limit") || "20", 10), 100);
    const offset = parseInt(url.searchParams.get("offset") || "0", 10);
    const sort = url.searchParams.get("sort") || "recent";

    let memories: MemoryRow[];

    if (q.trim()) {
      // Semantic search via fast_recall
      const typeFilter = type ? [type] : null;
      if (typeFilter) {
        memories = await prisma.$queryRawUnsafe<MemoryRow[]>(
          `SELECT r.memory_id AS id, r.content, r.memory_type AS type, r.score, r.source,
                  m.importance, m.trust_level, m.access_count, m.created_at,
                  m.last_accessed, m.metadata,
                  calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
                  CASE WHEN m.metadata->>'emotional_valence' ~ '^-?[0-9]+(\\.[0-9]+)?$'
                       THEN (m.metadata->>'emotional_valence')::float END AS emotional_valence
           FROM recall_memories_filtered($1, $2::integer, $3::memory_type[], 0.0::double precision) r
           JOIN memories m ON m.id = r.memory_id`,
          q,
          limit + offset,
          `{${type}}`
        );
      } else {
        memories = await prisma.$queryRawUnsafe<MemoryRow[]>(
          `SELECT r.memory_id AS id, r.content, r.memory_type AS type, r.score, r.source,
                  m.importance, m.trust_level, m.access_count, m.created_at,
                  m.last_accessed, m.metadata,
                  calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
                  CASE WHEN m.metadata->>'emotional_valence' ~ '^-?[0-9]+(\\.[0-9]+)?$'
                       THEN (m.metadata->>'emotional_valence')::float END AS emotional_valence
           FROM fast_recall($1, $2::integer) r
           JOIN memories m ON m.id = r.memory_id`,
          q,
          limit + offset
        );
      }
      // Apply offset manually since fast_recall doesn't support it
      memories = memories.slice(offset, offset + limit);
    } else {
      // Filtered listing
      const orderClause =
        sort === "importance"
          ? "ORDER BY importance DESC"
          : sort === "oldest"
            ? "ORDER BY created_at ASC"
            : "ORDER BY created_at DESC";

      const typeClause = type ? "AND type = $3::memory_type" : "";

      const query = `SELECT id, type, content, importance, trust_level, access_count,
                            created_at, last_accessed, metadata,
                            calculate_strength(importance, decay_rate, created_at, last_reinforced)::float AS strength,
                            CASE WHEN metadata->>'emotional_valence' ~ '^-?[0-9]+(\\.[0-9]+)?$'
                                 THEN (metadata->>'emotional_valence')::float END AS emotional_valence
                     FROM memories
                     WHERE status = 'active' ${typeClause}
                     ${orderClause}
                     LIMIT $1 OFFSET $2`;
      memories = type
        ? await prisma.$queryRawUnsafe<MemoryRow[]>(query, limit, offset, type)
        : await prisma.$queryRawUnsafe<MemoryRow[]>(query, limit, offset);
    }

    // Get memory health stats
    const healthRows = await prisma.$queryRawUnsafe<HealthRow[]>("SELECT * FROM memory_health");

    const totalCount = healthRows.reduce(
      (sum, h) => sum + Number(h.total_memories || 0),
      0
    );

    return NextResponse.json({
      memories: memories.map((m) => ({
        id: m.id,
        type: m.type ?? m.memory_type,
        content: m.content,
        importance: m.importance != null ? Number(m.importance) : null,
        trust_level: m.trust_level != null ? Number(m.trust_level) : null,
        score: m.score != null ? Number(m.score) : null,
        strength: m.strength != null ? Number(m.strength) : null,
        emotional_valence: m.emotional_valence != null ? Number(m.emotional_valence) : null,
        access_count: m.access_count != null ? Number(m.access_count) : null,
        created_at: m.created_at ?? null,
        last_accessed: m.last_accessed ?? null,
        metadata: normalizeJsonValue(m.metadata),
      })),
      health: healthRows.map((h) => ({
        type: h.type,
        count: Number(h.total_memories || 0),
        avg_importance: h.avg_importance != null ? Number(h.avg_importance) : null,
        avg_relevance: h.avg_relevance != null ? Number(h.avg_relevance) : null,
      })),
      total: totalCount,
      limit,
      offset,
    });
  } catch (error: unknown) {
    console.error("Memories API error:", error);
    return NextResponse.json(
      { error: errorMessage(error) },
      { status: 500 }
    );
  }
}
